#![cfg(target_os = "linux")]
use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    interactions::{FeatureEmitter, InteractionHub},
    local_tools::{LocalTools, LocalToolsConfig, Permission},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{
    fs,
    os::unix::fs::{MetadataExt, symlink},
    sync::Arc,
    time::Duration,
};
use tokio::sync::mpsc;
struct Emitter(mpsc::Sender<Value>);
impl FeatureEmitter for Emitter {
    fn emit<'a>(&'a self, v: Value) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            self.0.send(v).await?;
            Ok(())
        })
    }
}
fn ctx() -> TurnContext {
    TurnContext {
        conversation_id: "v4a-owner".into(),
        input_id: "v4a-input".into(),
        session_id: "v4a-session".into(),
    }
}
fn cfg(dir: &tempfile::TempDir, p: Permission) -> LocalToolsConfig {
    let mut c = LocalToolsConfig::new(
        "v4a-owner".into(),
        dir.path().join("root"),
        dir.path().join("state.sqlite"),
    );
    c.write = p;
    c
}
async fn setup(
    p: Permission,
    hub: Option<InteractionHub>,
) -> Result<(tempfile::TempDir, LocalTools)> {
    let d = tempfile::tempdir()?;
    fs::create_dir(d.path().join("root"))?;
    let t = LocalTools::open(cfg(&d, p), hub, None).await?;
    Ok((d, t))
}
async fn read(t: &LocalTools, path: &str) -> Result<()> {
    let r = t.execute("read_file", json!({"path":path}), &ctx()).await?;
    assert_eq!(r["complete_read"], true);
    Ok(())
}
async fn patch(t: &LocalTools, s: &str) -> Result<Value> {
    t.execute("patch", json!({"mode":"patch","patch":s}), &ctx())
        .await
}
const MIXED: &str = "*** Begin Patch\n*** Update File: a\n@@\n-old\n+new\n*** Move File: b -> moved\n*** Delete File: c\n*** Add File: added\n+created\n*** End Patch";
#[tokio::test]
async fn mixed_commit_read_before_write_modes_and_scoped_durable_receipt() -> Result<()> {
    let (d, t) = setup(Permission::Allow, None).await?;
    let root = d.path().join("root");
    for (n, b) in [("a", "old\n"), ("b", "move\n"), ("c", "delete\n")] {
        fs::write(root.join(n), b)?;
    }
    assert!(patch(&t, MIXED).await.is_err());
    for n in ["a", "b", "c"] {
        read(&t, n).await?;
    }
    let r = patch(&t, MIXED).await?;
    assert_eq!(r["status"], "committed", "{r}");
    assert!(
        r.get("error").is_none(),
        "committed tool results must not emit tool.failed: {r}"
    );
    assert_eq!(r["atomic_visibility"], false);
    assert_eq!(r["changes"].as_array().unwrap().len(), 5);
    assert_eq!(fs::read_to_string(root.join("a"))?, "new\n");
    assert_eq!(fs::read_to_string(root.join("moved"))?, "move\n");
    assert_eq!(fs::read_to_string(root.join("added"))?, "created");
    assert!(!root.join("b").exists() && !root.join("c").exists());
    assert_eq!(fs::metadata(root.join("moved"))?.mode() & 0o777, 0o600);
    assert!(!fs::read_dir(&root)?.any(|p| {
        p.unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".hermes-v4a-")
    }));
    let id = r["transaction_id"].clone();
    drop(t);
    let t = LocalTools::open(cfg(&d, Permission::Allow), None, None).await?;
    let status = t
        .execute(
            "patch",
            json!({"mode":"status","transaction_id":id}),
            &ctx(),
        )
        .await?;
    assert_eq!(status["status"], "committed");
    assert!(
        status.get("error").is_none(),
        "successful status receipt has no error key"
    );
    let mut other = ctx();
    other.session_id = "other".into();
    assert_eq!(
        t.execute(
            "patch",
            json!({"mode":"status","transaction_id":id}),
            &other
        )
        .await?["status"],
        "not_found"
    );
    assert!(patch(&t, MIXED).await.is_err());
    Ok(())
}
#[tokio::test]
async fn alias_cycles_and_all_target_validation_precede_any_effect() -> Result<()> {
    let (d, t) = setup(Permission::Allow, None).await?;
    let root = d.path().join("root");
    fs::write(root.join("a"), "A")?;
    fs::write(root.join("b"), "B")?;
    read(&t, "a").await?;
    read(&t, "b").await?;
    let r = patch(
        &t,
        "*** Move File: ./a -> tmp\n*** Move File: b -> a\n*** Move File: tmp -> ./b",
    )
    .await?;
    assert_eq!(r["status"], "committed", "{r}");
    assert_eq!(fs::read_to_string(root.join("a"))?, "B");
    assert_eq!(fs::read_to_string(root.join("b"))?, "A");
    assert!(!root.join("tmp").exists());
    let bad = "*** Add File: first\n+would-create\n*** Update File: missing\n@@\n-no\n+yes";
    assert!(patch(&t, bad).await.is_err());
    assert!(!root.join("first").exists());
    assert!(patch(&t, "*** Move File: a -> b").await.is_err());
    assert_eq!(fs::read_to_string(root.join("a"))?, "B");
    Ok(())
}
#[tokio::test]
async fn links_private_paths_special_files_and_missing_parents_fail_closed() -> Result<()> {
    let (d, t) = setup(Permission::Allow, None).await?;
    let root = d.path().join("root");
    fs::write(root.join("a"), "A")?;
    read(&t, "a").await?;
    symlink("a", root.join("alias"))?;
    fs::hard_link(root.join("a"), root.join("hard"))?;
    for p in [
        "alias",
        "hard",
        "a",
        ".env",
        ".hermes-v4a-reserved",
        "absent/child",
        "../outside",
    ] {
        assert!(
            patch(&t, &format!("*** Add File: {p}\n+x")).await.is_err(),
            "{p}"
        );
    }
    let fifo = std::ffi::CString::new(root.join("fifo").to_str().unwrap())?;
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
    assert!(patch(&t, "*** Delete File: fifo").await.is_err());
    Ok(())
}
async fn approval(rx: &mut mpsc::Receiver<Value>) -> Result<Value> {
    Ok(tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let v = rx.recv().await.unwrap();
            if v["type"] == "approval.request" {
                return v;
            }
        }
    })
    .await?)
}
#[tokio::test]
async fn whole_plan_approval_denial_cancel_and_stale_state_never_mutate() -> Result<()> {
    for decision in ["deny", "cancelled", "stale", "once"] {
        let (tx, mut rx) = mpsc::channel(16);
        let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
        let (d, t) = setup(Permission::Ask, Some(hub.clone())).await?;
        let root = d.path().join("root");
        fs::write(root.join("a"), "old\n")?;
        read(&t, "a").await?;
        let cloned = t.clone();
        let job = tokio::spawn(async move {
            patch(
                &cloned,
                "*** Update File: a\n@@\n-old\n+new\n*** Add File: second\n+two",
            )
            .await
        });
        let request = approval(&mut rx).await?;
        let text = request.to_string();
        assert!(
            text.contains("second")
                && text.contains("Replace a")
                && text.contains("not cross-file atomic"),
            "{text}"
        );
        if decision == "stale" {
            fs::write(root.join("a"), "external")?;
        }
        if decision == "cancelled" {
            t.cancel_conversation("v4a-owner").await;
        } else {
            hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"v4a-owner","decision":if decision=="stale"{"once"}else{decision}})).await?;
        }
        let result = job.await?;
        if decision == "once" {
            assert_eq!(result?["status"], "committed");
            assert_eq!(fs::read_to_string(root.join("second"))?, "two");
        } else {
            assert!(result.is_err(), "{decision}: {result:?}");
            assert!(!root.join("second").exists());
            assert_eq!(
                fs::read_to_string(root.join("a"))?,
                if decision == "stale" {
                    "external"
                } else {
                    "old\n"
                }
            );
        }
    }
    Ok(())
}
#[tokio::test]
async fn bounds_deny_and_strict_form_validation() -> Result<()> {
    let (d, t) = setup(Permission::Allow, None).await?;
    let too_many = (0..129)
        .map(|i| format!("*** Add File: f{i}\n+x\n"))
        .collect::<String>();
    assert!(patch(&t, &too_many).await.is_err());
    assert!(
        patch(
            &t,
            &format!("*** Add File: big\n+{}", "x".repeat(1024 * 1024))
        )
        .await
        .is_err()
    );
    for a in [
        json!({"mode":"patch","patch":"*** Add File: x\n+y","path":"x"}),
        json!({"mode":"status","transaction_id":4}),
        json!({"mode":"replace","patch":"*** Add File: x\n+y"}),
    ] {
        assert!(t.execute("patch", a, &ctx()).await.is_err());
    }
    assert_eq!(fs::read_dir(d.path().join("root"))?.count(), 0);
    drop(t);
    let t = LocalTools::open(cfg(&d, Permission::Deny), None, None).await?;
    assert!(patch(&t, "*** Add File: x\n+y").await.is_err());
    let schemas = t.schemas();
    let status_schema = schemas
        .iter()
        .find(|s| s["function"]["name"] == "patch")
        .expect("read-only status is available under Deny");
    assert_eq!(
        status_schema["function"]["parameters"]["properties"]["mode"]["enum"],
        json!(["status"])
    );
    assert_eq!(
        t.execute("patch", json!({"mode":"status"}), &ctx()).await?["status"],
        "not_found"
    );
    Ok(())
}
#[tokio::test]
async fn receipts_are_bounded_and_old_status_does_not_replay() -> Result<()> {
    let (d, t) = setup(Permission::Allow, None).await?;
    let mut first = Value::Null;
    for i in 0..70 {
        let r = patch(&t, &format!("*** Add File: x{i}\n+value")).await?;
        assert_eq!(r["status"], "committed");
        if i == 0 {
            first = r["transaction_id"].clone();
        }
    }
    assert_eq!(
        t.execute(
            "patch",
            json!({"mode":"status","transaction_id":first}),
            &ctx()
        )
        .await?["status"],
        "not_found"
    );
    assert_eq!(fs::read_dir(d.path().join("root"))?.count(), 70);
    let db = rusqlite::Connection::open(d.path().join("state.sqlite"))?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM local_v4a_receipts", [], |r| r
            .get::<_, i64>(0))?,
        64
    );
    Ok(())
}
#[tokio::test]
#[ignore = "actual filesystem fsync benchmark; run explicitly and preserve stdout"]
async fn benchmark_durable_transactions() -> Result<()> {
    for (files, bytes) in [(1, 4096), (10, 4096), (64, 4096), (10, 65536)] {
        let (d, t) = setup(Permission::Allow, None).await?;
        let root = d.path().join("root");
        for i in 0..files {
            fs::write(
                root.join(format!("f{i}")),
                format!("version 0\n{}", "x".repeat(bytes - 10)),
            )?;
        }
        for iteration in 0..30 {
            for i in 0..files {
                read(&t, &format!("f{i}")).await?;
            }
            let input = (0..files)
                .map(|i| {
                    format!(
                        "*** Update File: f{i}\n@@\n-version {iteration}\n+version {}\n",
                        iteration + 1
                    )
                })
                .collect::<String>();
            let cpu_start = benchmark_cpu_ns();
            let start = std::time::Instant::now();
            let r = patch(&t, &input).await?;
            let ns = start.elapsed().as_nanos();
            let cpu_ns = benchmark_cpu_ns() - cpu_start;
            assert_eq!(r["status"], "committed");
            println!(
                "{}",
                json!({"benchmark":"native_v4a_durable_transaction","files":files,"file_bytes":bytes,"iteration":iteration,"elapsed_ns":ns,"cpu_ns":cpu_ns,"includes":["planner","snapshot_checks","O_TMPFILE_staging","file_fsync","directory_fsync","SQLite_FULL_journal","receipt","cleanup"],"excludes":["initial_read_file","process_startup","human_approval","artifact_registration"]})
            );
        }
    }
    Ok(())
}

#[tokio::test]
async fn maximum_operation_batch_and_combined_input_limit() -> Result<()> {
    let (dir, tools) = setup(Permission::Allow, None).await?;
    let input = (0..128)
        .map(|i| format!("*** Add File: small{i}\n+value\n"))
        .collect::<String>();
    let result = patch(&tools, &input).await?;
    assert_eq!(result["status"], "committed");
    assert_eq!(result["changes"].as_array().unwrap().len(), 128);
    let root = dir.path().join("root");
    let body = format!("{}\n", "x".repeat(1023)).repeat(512);
    let mut input = String::new();
    for i in 0..17 {
        let path = format!("large{i}");
        fs::write(root.join(&path), &body)?;
        let mut offset = 1;
        loop {
            let read = tools
                .execute("read_file", json!({"path":path,"offset":offset}), &ctx())
                .await?;
            if read["complete_read"] == true {
                break;
            }
            offset = read["next_offset"]
                .as_u64()
                .expect("bounded pages make progress");
        }
        input.push_str(&format!("*** Delete File: {path}\n"));
    }
    assert!(patch(&tools, &input).await.is_err());
    for i in 0..17 {
        assert_eq!(
            fs::metadata(root.join(format!("large{i}")))?.len(),
            body.len() as u64
        );
    }
    Ok(())
}

fn benchmark_cpu_ns() -> u128 {
    let mut ts = std::mem::MaybeUninit::<libc::timespec>::zeroed();
    assert_eq!(
        unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, ts.as_mut_ptr()) },
        0
    );
    let ts = unsafe { ts.assume_init() };
    ts.tv_sec as u128 * 1_000_000_000 + ts.tv_nsec as u128
}
