#![cfg(target_os = "linux")]
use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    interactions::{FeatureEmitter, InteractionHub},
    local_tools::{LocalTools, LocalToolsConfig, Permission},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{fs, sync::Arc, time::Duration};
use tokio::sync::mpsc;
struct Emitter(mpsc::Sender<Value>);
impl FeatureEmitter for Emitter {
    fn emit<'a>(&'a self, frame: Value) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            self.0.send(frame).await?;
            Ok(())
        })
    }
}
fn context() -> TurnContext {
    TurnContext {
        conversation_id: "patch-owner".into(),
        input_id: "trusted-input".into(),
        session_id: "patch-session".into(),
    }
}
async fn setup(
    permission: Permission,
    hub: Option<InteractionHub>,
) -> Result<(tempfile::TempDir, LocalTools)> {
    let dir = tempfile::tempdir()?;
    fs::create_dir(dir.path().join("root"))?;
    let mut cfg = LocalToolsConfig::new(
        "patch-owner".into(),
        dir.path().join("root"),
        dir.path().join("state.sqlite"),
    );
    cfg.write = permission;
    Ok((dir, LocalTools::open(cfg, hub, None).await?))
}
async fn read(tools: &LocalTools, path: &str) -> Result<()> {
    let r = tools
        .execute("read_file", json!({"path":path}), &context())
        .await?;
    assert_eq!(r["complete_read"], true);
    Ok(())
}
#[tokio::test]
async fn actual_tool_fuzzy_preserves_indentation_and_reports_strategy() -> Result<()> {
    let (dir, tools) = setup(Permission::Allow, None).await?;
    let path = dir.path().join("root/a");
    fs::write(&path, "    function() {\n        old();\n    }\n")?;
    read(&tools, "a").await?;
    let out=tools.execute("patch",json!({"path":"a","old_string":"function() {\n    old();\n}","new_string":"function() {\n    new();\n}"}),&context()).await?;
    assert_eq!(out["strategy"], "line_trimmed");
    assert_eq!(out["match_count"], 1);
    assert_eq!(
        fs::read_to_string(path)?,
        "    function() {\n        new();\n    }\n"
    );
    Ok(())
}
#[tokio::test]
async fn fuzzy_still_requires_complete_read_and_unchanged_snapshot() -> Result<()> {
    let (dir, tools) = setup(Permission::Allow, None).await?;
    let path = dir.path().join("root/a");
    fs::write(&path, "  old\n")?;
    let args = json!({"path":"a","old_string":"old ","new_string":"new"});
    assert!(
        tools
            .execute("patch", args.clone(), &context())
            .await
            .is_err()
    );
    read(&tools, "a").await?;
    fs::write(&path, "  externally changed\n")?;
    assert!(tools.execute("patch", args, &context()).await.is_err());
    assert_eq!(fs::read_to_string(path)?, "  externally changed\n");
    Ok(())
}
#[tokio::test]
async fn ambiguous_escape_and_invalid_v4a_rejection_never_mutate() -> Result<()> {
    let (dir, tools) = setup(Permission::Allow, None).await?;
    let path = dir.path().join("root/a");
    let original = "  alpha\n  alpha\n";
    fs::write(&path, original)?;
    read(&tools, "a").await?;
    assert!(
        tools
            .execute(
                "patch",
                json!({"path":"a","old_string":"alpha ","new_string":"beta"}),
                &context()
            )
            .await
            .is_err()
    );
    assert!(
        tools
            .execute(
                "patch",
                json!({"mode":"unsupported","patch":"*** Delete File: a"}),
                &context()
            )
            .await
            .is_err()
    );
    assert_eq!(fs::read_to_string(&path)?, original);
    fs::write(&path, "a\nb")?;
    read(&tools, "a").await?;
    assert!(
        tools
            .execute(
                "patch",
                json!({"path":"a","old_string":"a\\nb","new_string":"x\\ny"}),
                &context()
            )
            .await
            .is_err()
    );
    assert_eq!(fs::read_to_string(path)?, "a\nb");
    Ok(())
}
#[tokio::test]
async fn approximate_preview_warns_and_stale_approval_cannot_write() -> Result<()> {
    let (tx, mut rx) = mpsc::channel(16);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let (dir, tools) = setup(Permission::Ask, Some(hub.clone())).await?;
    let path = dir.path().join("root/a");
    fs::write(&path, "let result = compute_value(100);\n")?;
    read(&tools, "a").await?;
    let t = tools.clone();
    let work = tokio::spawn(async move {
        t.execute("patch",json!({"path":"a","old_string":"let result = compute_value(101);","new_string":"let result = changed(100);"}),&context()).await
    });
    let approval = tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let v = rx.recv().await.unwrap();
            if v["type"] == "approval.request" {
                break v;
            }
        }
    })
    .await?;
    assert!(approval.to_string().contains("approximately"));
    fs::write(&path, "external content")?;
    hub.resolve(&json!({"type":"approval.resolve","request_id":approval["request_id"],"conversation_id":"patch-owner","decision":"once"})).await?;
    assert!(work.await?.is_err());
    assert_eq!(fs::read_to_string(path)?, "external content");
    Ok(())
}
