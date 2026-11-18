use anyhow::{Context, Result};
use hermes_rust_core::{
    ChatRequest, Core, Provider, Store,
    local_tools::{LocalTools, LocalToolsConfig, Permission},
    session_context::CompressionPolicy,
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::json;
use std::sync::Arc;

#[tokio::test]
async fn no_python_two_fresh_zero_generation_routes_should_not_exhaust_python_state() -> Result<()>
{
    let dir = tempfile::tempdir()?;
    let root = dir.path().join("root");
    std::fs::create_dir(&root)?;
    std::fs::write(root.join("fixture.txt"), "synthetic read-only fixture")?;
    let mut config = LocalToolsConfig::new(
        "synthetic-owner".into(),
        root,
        dir.path().join("local.sqlite"),
    );
    config.execute = Permission::Deny;
    config.write = Permission::Deny;
    config.max_session_routes = 1;
    assert!(config.python_program.is_none());
    let local = LocalTools::open(config, None, None).await?;
    let core = Core::new(
        Store::open(&dir.path().join("core.sqlite"))?,
        Provider::new(
            "http://127.0.0.1:1/v1/chat/completions".into(),
            "mock".into(),
            None,
            true,
        )?,
    )
    .with_session_context("synthetic-owner".into(), CompressionPolicy::default())?
    .with_tool_executors(vec![Arc::new(local.clone())])?;
    for route in ["route-one", "route-two"] {
        let context = TurnContext {
            conversation_id: route.into(),
            session_id: route.into(),
            input_id: format!("{route}-input"),
        };
        let result = core
            .chat_with_context(
                ChatRequest {
                    session_id: route.into(),
                    message: "read-only synthetic chat".into(),
                },
                context.clone(),
                None,
            )
            .await;
        if result.is_err() {
            eprintln!(
                "direct generation diagnostic for {route}: {:?}",
                local.set_session_generation(route, 0).await
            );
        }
        result.with_context(|| format!("fresh zero-generation {route}, with Python disabled, should not consume a permanent Python tombstone"))?;
        // Ordinary file dispatch must retain its generation guard; do not fix by bypassing it.
        let read = local
            .execute_at_generation("read_file", json!({"path":"fixture.txt"}), &context, 0)
            .await?;
        assert!(read.to_string().contains("synthetic read-only fixture"));
    }
    local.shutdown().await;
    Ok(())
}
