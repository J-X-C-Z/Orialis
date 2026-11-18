#![cfg(target_os = "linux")]
use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    interactions::{FeatureEmitter, InteractionHub},
    local_tools::{LocalTools, LocalToolsConfig, Permission, Program},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{fs, path::Path, sync::Arc, time::Duration};
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
        conversation_id: "owner-conversation".into(),
        input_id: "trusted-input".into(),
        session_id: "session".into(),
    }
}
fn config(root: &Path, state: &Path) -> LocalToolsConfig {
    let mut cfg = LocalToolsConfig::new("owner".into(), root.into(), state.into());
    cfg.programs = vec![
        Program {
            name: "python".into(),
            executable: "/usr/bin/python3".into(),
        },
        Program {
            name: "printf".into(),
            executable: "/usr/bin/printf".into(),
        },
    ];
    cfg.python_program = Some("python".into());
    cfg
}
fn directories() -> Result<(tempfile::TempDir, std::path::PathBuf, std::path::PathBuf)> {
    let dir = tempfile::tempdir()?;
    let root = dir.path().join("root");
    fs::create_dir(&root)?;
    let state = dir.path().join("tools.sqlite");
    Ok((dir, root, state))
}
async fn next_approval(rx: &mut mpsc::Receiver<Value>) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let v = rx.recv().await.unwrap();
            if v["type"] == "approval.request" {
                return v;
            }
        }
    })
    .await
    .unwrap()
}
async fn approve(hub: &InteractionHub, request: &Value, decision: &str) -> Result<()> {
    hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"owner-conversation","decision":decision})).await?;
    Ok(())
}
#[tokio::test]
async fn exact_approval_once_denial_and_stale_read_do_not_write() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let (tx, mut rx) = mpsc::channel(32);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let tools = LocalTools::open(config(&root, &state), Some(hub.clone()), None).await?;
    let t = tools.clone();
    let work = tokio::spawn(async move {
        t.execute(
            "write_file",
            json!({"path":"a.txt","content":"original"}),
            &context(),
        )
        .await
    });
    let request = next_approval(&mut rx).await;
    assert!(!root.join("a.txt").exists());
    approve(&hub, &request, "once").await?;
    assert_eq!(work.await??["verified"], true);
    assert_eq!(fs::read_to_string(root.join("a.txt"))?, "original");
    let t = tools.clone();
    let work = tokio::spawn(async move {
        t.execute(
            "patch",
            json!({"path":"a.txt","old_string":"original","new_string":"denied"}),
            &context(),
        )
        .await
    });
    let request = next_approval(&mut rx).await;
    approve(&hub, &request, "deny").await?;
    assert!(work.await?.is_err());
    assert_eq!(fs::read_to_string(root.join("a.txt"))?, "original");
    let t = tools.clone();
    let work = tokio::spawn(async move {
        t.execute(
            "patch",
            json!({"path":"a.txt","old_string":"original","new_string":"must not win"}),
            &context(),
        )
        .await
    });
    let request = next_approval(&mut rx).await;
    fs::write(root.join("a.txt"), "external change")?;
    approve(&hub, &request, "once").await?;
    assert!(work.await?.is_err());
    assert_eq!(fs::read_to_string(root.join("a.txt"))?, "external change");
    assert!(
        tools
            .execute(
                "write_file",
                json!({"path":"a.txt","content":"lost update"}),
                &context()
            )
            .await
            .is_err()
    );
    hub.shutdown().await?;
    Ok(())
}
#[tokio::test]
async fn paths_symlinks_hardlinks_and_private_files_fail_closed() -> Result<()> {
    let (dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg, None, None).await?;
    let secret = dir.path().join("outside.txt");
    fs::write(&secret, "synthetic private bytes")?;
    std::os::unix::fs::symlink(&secret, root.join("link"))?;
    fs::hard_link(&secret, root.join("hard"))?;
    fs::write(root.join(".env"), "SYNTHETIC_SECRET=private")?;
    for path in [
        "../outside.txt",
        "/etc/passwd",
        "link",
        "hard",
        ".env",
        ".git/config",
    ] {
        assert!(
            tools
                .execute("read_file", json!({"path":path}), &context())
                .await
                .is_err(),
            "{path}"
        );
        assert!(
            tools
                .execute(
                    "write_file",
                    json!({"path":path,"content":"bad"}),
                    &context()
                )
                .await
                .is_err(),
            "{path}"
        );
    }
    assert_eq!(fs::read_to_string(secret)?, "synthetic private bytes");
    assert!(
        tools
            .execute("read_file", json!({"path":22}), &context())
            .await
            .is_err()
    );
    assert!(
        tools
            .execute(
                "search_files",
                json!({"pattern":"private","path":22}),
                &context()
            )
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn file_patch_search_and_complete_read_guard_are_native() -> Result<()> {
    let (_dir, root, state) = directories()?;
    fs::write(root.join("old.txt"), "line one\nline two\nline two\n")?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg, None, None).await?;
    assert!(
        tools
            .execute(
                "write_file",
                json!({"path":"old.txt","content":"overwrite"}),
                &context()
            )
            .await
            .is_err()
    );
    let read = tools
        .execute("read_file", json!({"path":"old.txt","limit":1}), &context())
        .await?;
    assert_eq!(read["next_offset"], 2);
    assert!(
        tools
            .execute(
                "patch",
                json!({"path":"old.txt","old_string":"line one","new_string":"new"}),
                &context()
            )
            .await
            .is_err()
    );
    tools
        .execute("read_file", json!({"path":"old.txt"}), &context())
        .await?;
    assert!(
        tools
            .execute(
                "patch",
                json!({"path":"old.txt","old_string":"line two","new_string":"different"}),
                &context()
            )
            .await
            .is_err()
    );
    let out=tools.execute("patch",json!({"path":"old.txt","old_string":"line two","new_string":"replacement","replace_all":true}),&context()).await?;
    assert_eq!(out["verified"], true);
    let search = tools
        .execute(
            "search_files",
            json!({"pattern":"replacement","file_glob":"*.txt"}),
            &context(),
        )
        .await?;
    assert_eq!(search["matches"].as_array().unwrap().len(), 2);
    assert_eq!(
        tools
            .execute(
                "search_files",
                json!({"pattern":"*.txt","target":"files"}),
                &context()
            )
            .await?["matches"][0]["path"],
        "old.txt"
    );
    Ok(())
}
#[tokio::test]
async fn todo_and_skills_are_durable_atomic_and_session_scoped() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg.clone(), None, None).await?;
    tools.execute("todo_list",json!({"todos":[{"id":"one","content":"First step","status":"in_progress"},{"id":"two","content":"Second step","status":"pending","parent":"one"}]}),&context()).await?;
    assert!(tools.execute("todo_list",json!({"merge":true,"todos":[{"id":"two","content":"Second step","status":"in_progress"}]}),&context()).await.is_err());
    let mut other = context();
    other.conversation_id = "other-conversation".into();
    assert_eq!(
        tools.execute("todo_list", json!({}), &other).await?["todos"],
        json!([])
    );
    let content =
        "---\nname: test-skill\ndescription: Local test skill\n---\nUse literal files carefully.\n";
    tools.execute("skill_manage",json!({"operations":[{"action":"create","name":"test-skill","content":content},{"action":"write_file","name":"test-skill","file_path":"references/a.txt","file_content":"source"}]}),&context()).await?;
    assert!(tools.execute("skill_manage",json!({"operations":[{"action":"patch","name":"test-skill","old_string":"literal","new_string":"changed"},{"action":"write_file","name":"missing","file_path":"a","file_content":"no"}]}),&context()).await.is_err());
    assert!(
        tools
            .execute("skill_view", json!({"name":"test-skill"}), &context())
            .await?["content"]
            .as_str()
            .unwrap()
            .contains("literal")
    );
    drop(tools);
    let tools = LocalTools::open(cfg, None, None).await?;
    assert_eq!(
        tools.execute("todo_list", json!({}), &context()).await?["todos"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        tools
            .execute(
                "skill_view",
                json!({"name":"test-skill","file_path":"references/a.txt"}),
                &context()
            )
            .await?["content"],
        "source"
    );
    assert_eq!(
        tools.execute("skills_list", json!({}), &context()).await?["skills"][0]["name"],
        "test-skill"
    );
    Ok(())
}
#[tokio::test]
async fn sandbox_executes_real_program_without_private_files_env_network_or_fd_escape() -> Result<()>
{
    let (dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Allow;
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg, None, None).await?;
    let secret = dir.path().join("private-outside.txt");
    fs::write(&secret, "synthetic-secret")?;
    fs::write(root.join(".env"), "another-synthetic-secret")?;
    let code = format!(
        r#"import os,socket,json
r={{'cwd':os.getcwd(),'outside':os.path.exists({outside:?}),'environment':sorted(os.environ),'fds':[]}}
try:r['private']=open('/work/.env').read()
except PermissionError:r['private']='denied'
try: socket.socket();r['network']='unexpected'
except PermissionError:r['network']='denied'
for n in os.listdir('/proc/self/fd'):
 try:r['fds'].append(os.readlink('/proc/self/fd/'+n))
 except OSError:pass
print(json.dumps(r))
open('/work/generated.txt','w').write('actual sandbox output')
"#,
        outside = secret.to_string_lossy()
    );
    let result = tools
        .execute("execute_code", json!({"code":code}), &context())
        .await?;
    assert_eq!(result["exit_code"], 0, "{result}");
    let observed: Value = serde_json::from_str(result["output"].as_str().unwrap())?;
    assert_eq!(observed["cwd"], "/work");
    assert_eq!(observed["outside"], false);
    assert!(observed["private"] == "" || observed["private"] == "denied");
    assert_eq!(observed["network"], "denied");
    assert!(
        !observed["fds"]
            .to_string()
            .contains(dir.path().to_str().unwrap())
    );
    assert!(
        !observed["environment"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "AWS_SECRET_ACCESS_KEY" || v == "OPENAI_API_KEY")
    );
    assert_eq!(
        fs::read_to_string(root.join("generated.txt"))?,
        "actual sandbox output"
    );
    assert!(
        tools
            .execute(
                "terminal",
                json!({"command":"sh -c 'cat /etc/passwd'"}),
                &context()
            )
            .await
            .is_err()
    );
    assert!(
        tools
            .execute(
                "terminal",
                json!({"command":"printf hello; printf bad"}),
                &context()
            )
            .await
            .is_err()
    );
    tools.shutdown().await;
    Ok(())
}
#[tokio::test]
async fn background_process_scope_stdin_timeout_output_bound_and_restart_receipt() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Allow;
    cfg.write = Permission::Deny;
    cfg.output_bytes = 2048;
    let tools = LocalTools::open(cfg.clone(), None, None).await?;
    let process=tools.execute("terminal",json!({"command":"python -I -c 'import sys; print(sys.stdin.readline().strip()); print(\"x\"*10000)'","background":true}),&context()).await?;
    let id = process["session_id"].as_str().unwrap().to_owned();
    let mut other = context();
    other.session_id = "another-session".into();
    assert!(
        tools
            .execute(
                "process_manage",
                json!({"action":"poll","session_id":id}),
                &other
            )
            .await
            .is_err()
    );
    let write = tools
        .execute(
            "process_manage",
            json!({"action":"submit","session_id":id,"data":"actual input"}),
            &context(),
        )
        .await?;
    assert_eq!(write["stdin_complete"], true);
    let done = tools
        .execute(
            "process_manage",
            json!({"action":"wait","session_id":id,"timeout":5}),
            &context(),
        )
        .await?;
    assert_eq!(done["exit_code"], 0);
    assert!(done["output"].as_str().unwrap().len() <= 2048);
    assert_eq!(done["output_is_bounded_tail"], true);
    let timed = tools
        .execute(
            "terminal",
            json!({"command":"python -I -c 'import time; time.sleep(30)'","timeout":1}),
            &context(),
        )
        .await?;
    assert_eq!(timed["timed_out"], true);
    tools.shutdown().await;
    drop(tools);
    tokio::time::sleep(Duration::from_millis(20)).await;
    let tools = LocalTools::open(cfg, None, None).await?;
    assert_eq!(
        tools
            .execute(
                "process_manage",
                json!({"action":"poll","session_id":id}),
                &context()
            )
            .await?["exit_code"],
        0
    );
    Ok(())
}
#[tokio::test]
async fn denied_configuration_and_missing_sandbox_never_fall_back() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Deny;
    cfg.execute = Permission::Deny;
    let tools = LocalTools::open(cfg, None, None).await?;
    assert!(
        tools
            .execute(
                "write_file",
                json!({"path":"denied","content":"no"}),
                &context()
            )
            .await
            .is_err()
    );
    assert!(
        tools
            .execute(
                "terminal",
                json!({"command":"printf should-not-run"}),
                &context()
            )
            .await
            .is_err()
    );
    assert!(!root.join("denied").exists());
    drop(tools);
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Allow;
    cfg.write = Permission::Deny;
    cfg.sandbox = "/nonexistent/bwrap".into();
    let tools = LocalTools::open(cfg, None, None).await?;
    assert!(
        tools
            .execute("terminal", json!({"command":"printf bad"}), &context())
            .await
            .is_err()
    );
    Ok(())
}

#[tokio::test]
async fn execute_allow_cannot_override_write_deny_or_write_approval() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Allow;
    cfg.write = Permission::Deny;
    let tools = LocalTools::open(cfg, None, None).await?;
    let code = "try:\n open('/work/no-write.txt','w').write('blocked')\nexcept OSError:\n print('readonly enforced')";
    let result = tools
        .execute("execute_code", json!({"code":code}), &context())
        .await?;
    assert_eq!(result["exit_code"], 0, "{result}");
    assert!(
        result["output"]
            .as_str()
            .unwrap()
            .contains("readonly enforced")
    );
    assert!(!root.join("no-write.txt").exists());
    tools.shutdown().await;
    drop(tools);
    tokio::time::sleep(Duration::from_millis(10)).await;
    let (tx, mut rx) = mpsc::channel(16);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Allow;
    cfg.write = Permission::Ask;
    let tools = LocalTools::open(cfg, Some(hub.clone()), None).await?;
    let t = tools.clone();
    let work = tokio::spawn(async move {
        t.execute(
            "terminal",
            json!({"command":"printf needs-write-approval"}),
            &context(),
        )
        .await
    });
    let request = next_approval(&mut rx).await;
    assert!(!work.is_finished());
    approve(&hub, &request, "deny").await?;
    assert!(work.await?.is_err());
    let t = tools.clone();
    let work = tokio::spawn(async move {
        t.execute(
            "write_file",
            json!({"path":"cancelled.txt","content":"not authorized"}),
            &context(),
        )
        .await
    });
    next_approval(&mut rx).await;
    tools.cancel_conversation("owner-conversation").await;
    assert!(work.await?.is_err());
    assert!(!root.join("cancelled.txt").exists());
    hub.shutdown().await?;
    Ok(())
}
#[tokio::test]
async fn sandbox_denies_fork_and_bounds_invalid_utf8_output() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Allow;
    cfg.write = Permission::Deny;
    cfg.output_bytes = 2048;
    let tools = LocalTools::open(cfg, None, None).await?;
    let result=tools.execute("execute_code",json!({"code":"import os\ntry:\n os.fork()\n print('unexpected fork')\nexcept PermissionError:\n print('fork denied')"}),&context()).await?;
    assert_eq!(result["exit_code"], 0, "{result}");
    assert!(result["output"].as_str().unwrap().contains("fork denied"));
    let output = tools
        .execute(
            "execute_code",
            json!({"code":"import os; os.write(1, b'\\xff'*10000)"}),
            &context(),
        )
        .await?;
    assert_eq!(output["exit_code"], 0);
    assert!(output["output"].as_str().unwrap().len() <= 2048);
    tools.shutdown().await;
    Ok(())
}
#[tokio::test]
async fn consecutive_pages_authorize_only_the_unchanged_complete_file() -> Result<()> {
    let (_dir, root, state) = directories()?;
    fs::write(root.join("paged.txt"), "first\nsecond\nthird\n")?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg, None, None).await?;
    tools
        .execute(
            "read_file",
            json!({"path":"paged.txt","offset":1,"limit":1}),
            &context(),
        )
        .await?;
    let read = tools
        .execute(
            "read_file",
            json!({"path":"paged.txt","offset":2,"limit":2}),
            &context(),
        )
        .await?;
    assert_eq!(read["complete_read"], true);
    tools
        .execute(
            "patch",
            json!({"path":"paged.txt","old_string":"second","new_string":"changed"}),
            &context(),
        )
        .await?;
    assert!(fs::read_to_string(root.join("paged.txt"))?.contains("changed"));
    Ok(())
}
#[tokio::test]
async fn generated_file_registers_exact_private_snapshot_without_upload() -> Result<()> {
    use hermes_rust_core::{
        attachments::{AttachmentConfig, AttachmentTransport},
        output_files::{OutputConfig, OutputFiles, OutputScope},
    };
    let (dir, root, state) = directories()?;
    let transport = AttachmentTransport::new(AttachmentConfig::new(
        "http://127.0.0.1:9".into(),
        "synthetic-device".into(),
        "synthetic-token".into(),
        dir.path().join("cache"),
    ))?;
    let outputs = OutputFiles::open(
        OutputConfig::new(
            dir.path().join("artifacts.sqlite"),
            dir.path().join("spool"),
        ),
        transport,
    )
    .await?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Allow;
    let tools = LocalTools::open(cfg, None, Some(outputs.clone())).await?;
    let result = tools
        .execute(
            "write_file",
            json!({"path":"generated.txt","content":"the actual generated artifact"}),
            &context(),
        )
        .await?;
    assert_eq!(result["verified"], true);
    let reference = result["media_reference"].as_str().unwrap();
    let scope = OutputScope {
        conversation_id: context().conversation_id,
        input_id: context().input_id,
    };
    fs::write(root.join("generated.txt"), "changed after registration")?;
    let handle = outputs.resolve_media(&scope, reference).await?;
    assert_eq!(handle.sha256, result["sha256"].as_str().unwrap());
    assert!(
        outputs
            .outcome(&scope, &handle.artifact_id)
            .await?
            .is_none()
    );
    let wrong = OutputScope {
        conversation_id: scope.conversation_id,
        input_id: "other-input".into(),
    };
    assert!(outputs.resolve_media(&wrong, reference).await.is_err());
    Ok(())
}

#[tokio::test]
async fn real_core_awaits_approval_then_commits_one_local_effect_and_receipt() -> Result<()> {
    use axum::{Json, Router, extract::State, routing::post};
    use hermes_rust_core::{
        ChatRequest, Core, Provider, Store, session_context::CompressionPolicy,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    async fn model(
        State(calls): State<Arc<AtomicUsize>>,
        Json(payload): Json<Value>,
    ) -> Json<Value> {
        let n = calls.fetch_add(1, Ordering::SeqCst);
        let message = if n == 0 {
            json!({"role":"assistant","content":null,"tool_calls":[{"id":"real-local-write","type":"function","function":{"name":"write_file","arguments":json!({"path":"from-core.txt","content":"actual approved effect"}).to_string()}}]})
        } else {
            assert!(payload["messages"].to_string().contains("verified"));
            json!({"role":"assistant","content":"The approved file is saved."})
        };
        Json(json!({"choices":[{"message":message,"finish_reason":"stop"}]}))
    }
    let (dir, root, state) = directories()?;
    let (tx, mut rx) = mpsc::channel(16);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let tools = LocalTools::open(config(&root, &state), Some(hub.clone()), None).await?;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("http://{}/v1/chat/completions", listener.local_addr()?);
    let calls = Arc::new(AtomicUsize::new(0));
    let app = Router::new()
        .route("/v1/chat/completions", post(model))
        .with_state(calls.clone());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let core = Core::new(
        Store::open(&dir.path().join("core.sqlite"))?,
        Provider::new(endpoint, "controlled-local-model".into(), None, false)?,
    )
    .with_tool_executors(vec![Arc::new(tools.clone())])?
    .with_session_context("owner".into(), CompressionPolicy::default())?;
    let c = core.clone();
    let task = tokio::spawn(async move {
        c.chat_with_context(
            ChatRequest {
                session_id: "session".into(),
                message: "Write the file".into(),
            },
            context(),
            None,
        )
        .await
    });
    let request = next_approval(&mut rx).await;
    assert!(!root.join("from-core.txt").exists());
    approve(&hub, &request, "once").await?;
    assert_eq!(task.await??.answer, "The approved file is saved.");
    assert_eq!(
        fs::read_to_string(root.join("from-core.txt"))?,
        "actual approved effect"
    );
    assert_eq!(core.history("session".into()).await?.len(), 4);
    let replay = core
        .chat_with_context(
            ChatRequest {
                session_id: "session".into(),
                message: "Write the file".into(),
            },
            context(),
            None,
        )
        .await?;
    assert_eq!(replay.provider_calls, 0);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    tools.shutdown().await;
    hub.shutdown().await?;
    server.abort();
    Ok(())
}
