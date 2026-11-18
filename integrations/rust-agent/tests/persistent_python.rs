#![cfg(target_os = "linux")]
use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    interactions::{FeatureEmitter, InteractionHub},
    local_tools::{LocalTools, LocalToolsConfig, Permission, Program, PythonBridge},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{
    fs,
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::mpsc;

fn context(input: &str) -> TurnContext {
    TurnContext {
        conversation_id: "conversation-a".into(),
        session_id: "session-a".into(),
        input_id: input.into(),
    }
}
fn config(root: &Path, state: &Path) -> LocalToolsConfig {
    let mut cfg = LocalToolsConfig::new("synthetic-owner".into(), root.into(), state.into());
    cfg.programs = vec![Program {
        name: "python".into(),
        executable: "/usr/bin/python3".into(),
    }];
    cfg.python_program = Some("python".into());
    cfg.write = Permission::Allow;
    cfg.execute = Permission::Allow;
    cfg.timeout = Duration::from_secs(3);
    cfg
}
fn directories() -> Result<(tempfile::TempDir, std::path::PathBuf, std::path::PathBuf)> {
    let dir = tempfile::tempdir()?;
    let root = dir.path().join("workspace");
    fs::create_dir(&root)?;
    let state = dir.path().join("state.sqlite");
    Ok((dir, root, state))
}
async fn cell(tools: &LocalTools, code: &str) -> Result<Value> {
    tools
        .execute("execute_code", json!({"code":code}), &context("input"))
        .await
}
fn ok(v: &Value) {
    assert_eq!(v["status"], "ok", "{v}");
    assert_eq!(v["exit_code"], 0, "{v}");
}

#[tokio::test]
async fn real_state_crosses_cells_and_inputs_but_not_sessions_or_reset() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let a = cell(
        &tools,
        "import math\nx = [2]\ndef double(n): return n * 2\nprint('first')",
    )
    .await?;
    ok(&a);
    assert_eq!(a["kernel"]["reused"], false);
    assert_eq!(a["kernel"]["execution_count"], 1);
    let b = tools
        .execute(
            "execute_code",
            json!({"code":"x.append(3); print(double(sum(x)), math.isqrt(81))"}),
            &context("next-input"),
        )
        .await?;
    ok(&b);
    assert_eq!(b["output"], "10 9\n");
    assert_eq!(b["kernel"]["reused"], true);
    assert_eq!(b["kernel"]["execution_count"], 2);
    let mut other = context("other-input");
    other.session_id = "session-b".into();
    let v = tools
        .execute(
            "execute_code",
            json!({"code":"print('x' in globals())"}),
            &other,
        )
        .await?;
    ok(&v);
    assert_eq!(v["output"], "False\n");
    let reset = tools
        .execute(
            "execute_code",
            json!({"reset":true,"code":"print('x' in globals())"}),
            &context("reset"),
        )
        .await?;
    ok(&reset);
    assert_eq!(reset["kernel"]["state_reset"], true);
    assert_eq!(reset["kernel"]["reused"], false);
    assert_eq!(reset["kernel"]["execution_count"], 1);
    assert_eq!(reset["output"], "False\n");
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn local_bridge_reuses_real_rust_executors_with_bounded_results() -> Result<()> {
    let (_dir, root, state) = directories()?;
    fs::write(root.join("a.txt"), "hello")?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let v=cell(&tools,r#"from hermes_tools import read_file, write_file, patch, search_files, todo_list, json_parse, shell_quote
assert 'hello' in read_file('a.txt')['content']
assert write_file('a.txt', 'new text')['verified']
assert patch('a.txt', 'new', 'updated')['verified']
print(read_file('a.txt')['content'].strip())
print(len(search_files('updated')['matches']))
print(todo_list(todos=[{'id':'1','content':'test','status':'pending'}])['todos'][0]['id'])
print(json_parse('\ufeff{"a":1}')['a'], shell_quote('two words'))
"#).await?;
    ok(&v);
    assert_eq!(v["tool_calls_made"], 6, "{v}");
    assert!(v["output"].as_str().unwrap().contains("updated text"));
    assert_eq!(fs::read_to_string(root.join("a.txt"))?, "updated text");
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn callback_allowlist_budget_and_write_policy_are_enforced_by_host() -> Result<()> {
    let (_dir, root, state) = directories()?;
    fs::write(root.join("data"), "small")?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Deny;
    cfg.python_max_tool_calls = 2;
    let tools = LocalTools::open(cfg, None, None).await?;
    let denied = cell(
        &tools,
        r#"import __main__ as runtime
print(runtime._call('write_file', {'path':'bad','content':'bad'}))
print(runtime._call('terminal', {'command':'python -c "print(1)"'}))
"#,
    )
    .await?;
    ok(&denied);
    assert_eq!(denied["tool_errors"].as_array().unwrap().len(), 2);
    assert!(!root.join("bad").exists());
    let budget = cell(
        &tools,
        "from hermes_tools import read_file\nfor _ in range(3): read_file('data')",
    )
    .await?;
    assert_eq!(budget["status"], "error", "{budget}");
    assert_eq!(budget["tool_calls_made"], 2);
    assert_eq!(budget["kernel"]["state_lost"], true);
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn exception_keeps_state_system_exit_ends_it_and_host_restart_is_fresh() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let cfg = config(&root, &state);
    let tools = LocalTools::open(cfg.clone(), None, None).await?;
    let v = cell(&tools, "x=7\nraise ValueError('expected')").await?;
    assert_eq!(v["status"], "error");
    assert_eq!(v["exit_code"], 1);
    let v = cell(&tools, "print(x)").await?;
    ok(&v);
    assert_eq!(v["output"], "7\n");
    let v = cell(&tools, "raise SystemExit(0)").await?;
    ok(&v);
    assert_eq!(v["kernel"]["ended"], true);
    let v = cell(&tools, "print('x' in globals()); x=99").await?;
    ok(&v);
    assert_eq!(v["output"], "False\n");
    tools.shutdown().await;
    drop(tools);
    let tools = LocalTools::open(cfg, None, None).await?;
    let v = cell(&tools, "print('x' in globals())").await?;
    ok(&v);
    assert_eq!(v["output"], "False\n");
    assert_eq!(v["kernel"]["ephemeral"], true);
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn timeout_and_cancel_kill_actual_kernel_without_replaying_partial_effects() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.timeout = Duration::from_millis(150);
    let tools = LocalTools::open(cfg, None, None).await?;
    let v = cell(
        &tools,
        "x=1\nopen('/work/once','w').write('once')\nimport time; time.sleep(1)",
    )
    .await?;
    assert_eq!(v["status"], "timeout", "{v}");
    assert_eq!(v["kernel"]["state_lost"], true);
    assert_eq!(fs::read_to_string(root.join("once"))?, "once");
    let v = cell(&tools, "print('x' in globals())").await?;
    ok(&v);
    assert_eq!(v["output"], "False\n");
    let work = {
        let t = tools.clone();
        tokio::spawn(async move {
            cell(&t,"open('/work/started','w').write('1')\nimport time; time.sleep(1)\nopen('/work/late','w').write('bad')").await
        })
    };
    for _ in 0..100 {
        if root.join("started").exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    tools.cancel_conversation("conversation-a").await;
    let v = work.await??;
    assert_eq!(v["status"], "interrupted", "{v}");
    assert!(!root.join("late").exists());
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn aborting_caller_future_stops_execution_not_just_the_wait() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let work = {
        let t = tools.clone();
        tokio::spawn(async move {
            cell(&t,"open('/work/started','w').write('1')\nimport time; time.sleep(.3)\nopen('/work/late','w').write('bad')").await
        })
    };
    for _ in 0..300 {
        if root.join("started").exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    assert!(root.join("started").exists());
    work.abort();
    let _ = work.await;
    tokio::time::sleep(Duration::from_millis(350)).await;
    assert!(!root.join("late").exists());
    let v = cell(&tools, "print('fresh')").await?;
    ok(&v);
    assert_eq!(v["kernel"]["reused"], false);
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn forged_completion_cannot_run_between_cells_or_dispatch_stale_callbacks() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let forged = cell(
        &tools,
        r#"import __main__ as runner, time
runner._send({'kind':'complete','id':runner._cell,'status':'ok','error':''})
time.sleep(.05)
open('/work/unauthorized-idle-effect','w').write('bad')
"#,
    )
    .await?;
    ok(&forged);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(!root.join("unauthorized-idle-effect").exists());
    let reset = tools
        .execute(
            "execute_code",
            json!({"reset":true,"code":"print('reset')"}),
            &context("reset"),
        )
        .await?;
    ok(&reset);
    assert!(!root.join("unauthorized-idle-effect").exists());
    let stale=cell(&tools,r#"import __main__ as r
r._send({'kind':'call','id':'old-cell','sequence':1,'name':'write_file','arguments':{'path':'stale-effect','content':'bad'}})
"#).await?;
    assert_eq!(stale["status"], "error", "{stale}");
    assert_eq!(stale["tool_calls_made"], 0);
    assert!(!root.join("stale-effect").exists());
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn raw_output_and_protocol_flood_are_bounded_without_deadlock() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.output_bytes = 2048;
    cfg.timeout = Duration::from_millis(200);
    let tools = LocalTools::open(cfg, None, None).await?;
    let v = cell(
        &tools,
        "import os\nos.write(1,b'\\xff'*100000)\nprint('tail')",
    )
    .await?;
    ok(&v);
    assert!(v["output"].as_str().unwrap().len() <= 2048);
    assert_eq!(v["output_truncated"], true);
    assert!(v["output"].as_str().unwrap().ends_with("tail\n"));
    let v = cell(
        &tools,
        "import __main__ as r\nr._wire.write(r._SENTINEL + b'3145728\\n' + b'x'*8192)",
    )
    .await?;
    assert_eq!(v["status"], "error", "{v}");
    assert!(v["error"].as_str().unwrap().contains("frame exceeds bound"));
    let v = cell(&tools, "import os\nwhile True: os.write(1,b'x'*8192)").await?;
    assert_eq!(v["status"], "timeout");
    assert!(v["output"].as_str().unwrap().len() <= 2048);
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn warm_cells_revalidate_private_masks_and_new_links() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    ok(&cell(&tools, "x=5").await?);
    fs::write(root.join(".env"), "synthetic-private")?;
    assert!(
        cell(&tools, "print(open('/work/.env').read())")
            .await
            .is_err()
    );
    let v = cell(
        &tools,
        "try:\n print(open('/work/.env').read())\nexcept PermissionError:\n print('denied')\nprint('x' in globals())",
    )
    .await?;
    ok(&v);
    assert!(v["output"] == "\nFalse\n" || v["output"] == "denied\nFalse\n");
    std::os::unix::fs::symlink("/etc/passwd", root.join("link"))?;
    assert!(cell(&tools, "print('must not run')").await.is_err());
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn idle_expiry_cell_limit_and_shared_process_slots_are_real() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.max_processes = 1;
    cfg.python_idle_timeout = Duration::from_millis(150);
    cfg.python_max_cells = 2;
    let tools = LocalTools::open(cfg, None, None).await?;
    ok(&cell(&tools, "x=9").await?);
    assert!(
        tools
            .execute(
                "terminal",
                json!({"command":"python -c 'print(1)'"}),
                &context("terminal")
            )
            .await
            .is_err()
    );
    ok(&cell(&tools, "print(x)").await?);
    assert!(cell(&tools, "print(x)").await.is_err());
    let v = cell(&tools, "print('x' in globals())").await?;
    ok(&v);
    assert_eq!(v["output"], "False\n");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let v = cell(&tools, "print('fresh')").await?;
    ok(&v);
    assert_eq!(v["kernel"]["reused"], false);
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn generation_reset_is_idempotent_and_fences_stale_prepared_calls() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    tools.set_session_generation("session-a", 0).await?;
    let v = tools
        .execute_at_generation("execute_code", json!({"code":"x=1"}), &context("old"), 0)
        .await?;
    ok(&v);
    tools.set_session_generation("session-a", 1).await?;
    assert!(
        tools
            .execute_at_generation(
                "execute_code",
                json!({"code":"open('/work/stale','w').write('bad')"}),
                &context("stale"),
                0
            )
            .await
            .is_err()
    );
    let v = tools
        .execute_at_generation(
            "execute_code",
            json!({"code":"print('x' in globals()); x=2"}),
            &context("new"),
            1,
        )
        .await?;
    ok(&v);
    assert_eq!(v["output"], "False\n");
    tools.set_session_generation("session-a", 1).await?;
    let _ = tools.set_session_generation("session-a", 0).await;
    let v = tools
        .execute_at_generation(
            "execute_code",
            json!({"code":"print(x)"}),
            &context("new2"),
            1,
        )
        .await?;
    ok(&v);
    assert_eq!(v["output"], "2\n");
    assert!(!root.join("stale").exists());
    tools.shutdown().await;
    Ok(())
}

struct Emitter(mpsc::Sender<Value>);
impl FeatureEmitter for Emitter {
    fn emit<'a>(&'a self, v: Value) -> BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            self.0.send(v).await?;
            Ok(())
        })
    }
}
async fn request(rx: &mut mpsc::Receiver<Value>) -> Value {
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
async fn resolve(hub: &InteractionHub, request: &Value, decision: &str) -> Result<()> {
    hub.resolve(&json!({"type":"approval.resolve","conversation_id":"conversation-a","request_id":request["request_id"],"decision":decision})).await?;
    Ok(())
}
#[tokio::test]
async fn each_cell_and_write_callback_needs_its_own_exact_approval() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.execute = Permission::Ask;
    cfg.write = Permission::Ask;
    cfg.timeout = Duration::from_secs(5);
    let (tx, mut rx) = mpsc::channel(20);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let tools = LocalTools::open(cfg, Some(hub.clone()), None).await?;
    let work = {
        let t = tools.clone();
        tokio::spawn(async move {
            cell(&t,"from hermes_tools import write_file\nprint(write_file('approved','yes'))\nprint(write_file('denied','no'))").await
        })
    };
    resolve(&hub, &request(&mut rx).await, "once").await?;
    let first = request(&mut rx).await;
    assert!(!root.join("approved").exists());
    resolve(&hub, &first, "once").await?;
    let second = request(&mut rx).await;
    assert!(root.join("approved").exists());
    assert!(!root.join("denied").exists());
    resolve(&hub, &second, "deny").await?;
    let v = work.await??;
    ok(&v);
    assert_eq!(v["tool_errors"].as_array().unwrap().len(), 1);
    assert!(!root.join("denied").exists());
    let work = {
        let t = tools.clone();
        tokio::spawn(async move { cell(&t, "print('not approved')").await })
    };
    request(&mut rx).await;
    tools.cancel_conversation("conversation-a").await;
    assert!(work.await?.is_err());
    tools.shutdown().await;
    hub.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn reset_during_callback_approval_does_not_deadlock_or_apply_old_write() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.write = Permission::Ask;
    cfg.timeout = Duration::from_secs(5);
    let (tx, mut rx) = mpsc::channel(20);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let tools = LocalTools::open(cfg, Some(hub.clone()), None).await?;
    tools.set_session_generation("session-a", 0).await?;
    let work = {
        let t = tools.clone();
        tokio::spawn(async move {
            t.execute_at_generation("execute_code",json!({"code":"from hermes_tools import write_file\nwrite_file('old-effect','bad')"}),&context("old"),0).await
        })
    };
    resolve(&hub, &request(&mut rx).await, "once").await?;
    let pending = request(&mut rx).await;
    tokio::time::timeout(
        Duration::from_secs(1),
        tools.set_session_generation("session-a", 1),
    )
    .await??;
    let _ = resolve(&hub, &pending, "once").await;
    let v = tokio::time::timeout(Duration::from_secs(1), work).await???;
    assert_eq!(v["status"], "interrupted", "{v}");
    assert!(!root.join("old-effect").exists());
    tools.shutdown().await;
    hub.shutdown().await?;
    Ok(())
}

struct EchoScope;
impl ToolExecutor for EchoScope {
    fn schemas(&self) -> Vec<Value> {
        vec![
            json!({"type":"function","function":{"name":"verified_scope","parameters":{"type":"object"}}}),
        ]
    }
    fn execute<'a>(
        &'a self,
        _: &'a str,
        args: Value,
        c: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(
            async move { Ok(json!({"input":c.input_id,"session":c.session_id,"untrusted":args})) },
        )
    }
}
#[tokio::test]
async fn host_extension_is_explicit_and_receives_current_trusted_turn() -> Result<()> {
    let (_dir, root, state) = directories()?;
    assert!(PythonBridge::new(Arc::new(EchoScope), vec!["execute_code".into()]).is_err());
    assert!(PythonBridge::new(Arc::new(EchoScope), vec!["unregistered".into()]).is_err());
    let bridge = PythonBridge::new(Arc::new(EchoScope), vec!["verified_scope".into()])?;
    let tools =
        LocalTools::open_with_python_bridge(config(&root, &state), None, None, Some(bridge))
            .await?;
    let v=tools.execute("execute_code",json!({"code":"from hermes_tools import verified_scope\nprint(verified_scope(input_id='fake')['input'])"}),&context("trusted-first")).await?;
    ok(&v);
    assert_eq!(v["output"], "trusted-first\n");
    let v = tools
        .execute(
            "execute_code",
            json!({"code":"print(verified_scope()['input'])"}),
            &context("trusted-next"),
        )
        .await?;
    ok(&v);
    assert_eq!(v["output"], "trusted-next\n");
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn large_cell_request_uses_pipes_without_partial_write_success() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let code = format!("value={:?}\nprint(len(value))", "x".repeat(100_000));
    let v = cell(&tools, &code).await?;
    ok(&v);
    assert_eq!(v["output"], "100000\n");
    tools.shutdown().await;
    Ok(())
}

fn host_cpu_us() -> u64 {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    assert_eq!(
        unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) },
        0
    );
    let usage = unsafe { usage.assume_init() };
    (usage.ru_utime.tv_sec as u64 + usage.ru_stime.tv_sec as u64) * 1_000_000
        + usage.ru_utime.tv_usec as u64
        + usage.ru_stime.tv_usec as u64
}
fn rss_kib(pid: u32) -> u64 {
    fs::read_to_string(format!("/proc/{pid}/status"))
        .unwrap_or_default()
        .lines()
        .find(|line| line.starts_with("VmRSS:"))
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}
fn owned_child_rss_kib() -> (u64, usize) {
    // Some Linux procfs builds omit task/*/children. Parent IDs are still
    // available; inspect only ownership metadata, then RSS of our descendants.
    let mut parents = std::collections::HashMap::<u32, Vec<u32>>::new();
    for entry in fs::read_dir("/proc")
        .expect("benchmark requires visible procfs")
        .flatten()
    {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        let Ok(status) = fs::read_to_string(entry.path().join("status")) else {
            continue;
        };
        let parent = status
            .lines()
            .find(|line| line.starts_with("PPid:"))
            .and_then(|line| line.split_whitespace().nth(1))
            .and_then(|s| s.parse::<u32>().ok());
        if let Some(parent) = parent {
            parents.entry(parent).or_default().push(pid);
        }
    }
    let mut pending = vec![std::process::id()];
    let mut seen = std::collections::HashSet::new();
    let mut rss = 0;
    while let Some(pid) = pending.pop() {
        for child in parents.get(&pid).into_iter().flatten() {
            if seen.insert(*child) {
                rss += rss_kib(*child);
                pending.push(*child);
            }
        }
        assert!(
            seen.len() < 32,
            "unexpected process tree in isolated benchmark"
        );
    }
    (rss, seen.len())
}

fn distribution(mut values: Vec<f64>) -> Value {
    values.sort_by(f64::total_cmp);
    json!({"p50":values[values.len()/2],"p95":values[(values.len()*95/100).min(values.len()-1)],"min":values[0],"max":values[values.len()-1]})
}
/// Opt-in isolated measurement; not included in normal tests. Cold cells reset
/// the real sandbox; warm cells reuse it. All outputs are checked, not mocked.
#[tokio::test]
#[ignore = "run alone after builds settle, with --nocapture --test-threads=1"]
async fn measure_cold_warm_cells() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let host_baseline_rss = rss_kib(std::process::id());
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let mut cold = Vec::new();
    let mut warm = Vec::new();
    let mut cold_cpu = Vec::new();
    let mut warm_cpu = Vec::new();
    for _ in 0..25 {
        let t = Instant::now();
        let cpu = host_cpu_us();
        let v = tools
            .execute(
                "execute_code",
                json!({"reset":true,"code":"x=0; print(1)"}),
                &context("bench"),
            )
            .await?;
        ok(&v);
        assert_eq!(v["output"], "1\n");
        cold.push(t.elapsed().as_secs_f64() * 1000.);
        cold_cpu.push((host_cpu_us() - cpu) as f64);
        let t = Instant::now();
        let cpu = host_cpu_us();
        let v = cell(&tools, "x+=1; print(x)").await?;
        ok(&v);
        assert_eq!(v["output"], "1\n");
        warm.push(t.elapsed().as_secs_f64() * 1000.);
        warm_cpu.push((host_cpu_us() - cpu) as f64);
    }
    let (child_rss, child_count) = owned_child_rss_kib();
    assert!(
        child_count > 0 && child_rss > 0,
        "kernel RSS measurement unavailable; do not report zero memory"
    );
    let idle_cpu = host_cpu_us();
    let idle_start = Instant::now();
    tokio::time::sleep(Duration::from_secs(1)).await;
    let idle_cpu = host_cpu_us() - idle_cpu;
    let host_rss = rss_kib(std::process::id());
    tools.shutdown().await;
    println!(
        "{}",
        json!({
            "samples_each":25,"profile":if cfg!(debug_assertions){"debug"}else{"release"},
            "cold_ms":distribution(cold),"warm_ms":distribution(warm),
            "host_cpu_us_cold":distribution(cold_cpu),"host_cpu_us_warm":distribution(warm_cpu),
            "rss_kib":{"host_before_service":host_baseline_rss,"host_with_idle_kernel":host_rss,"owned_sandbox_processes":child_rss,"sandbox_process_count":child_count},
            "host_idle_cpu_us":idle_cpu,"idle_observation_seconds":idle_start.elapsed().as_secs_f64(),
            "owned_processes_after_shutdown":owned_child_rss_kib().1,
            "note":"Empty synthetic workspace. Host CPU excludes Python/Bubblewrap. RSS is a sum of resident sizes, not proportional memory; shared pages can be counted more than once."
        })
    );
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn lifecycle_reset_keeps_single_thread_event_loop_responsive() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.max_processes = 1;
    let tools = LocalTools::open(cfg, None, None).await?;
    let work = {
        let tools = tools.clone();
        tokio::spawn(async move {
            tools.execute_at_generation("execute_code", json!({"code":"open('/work/started','w').write('ready')\nimport time; time.sleep(10)"}), &context("old"), 0).await
        })
    };
    for _ in 0..300 {
        if root.join("started").exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(1)).await;
    }
    assert!(root.join("started").exists());
    let tick = tokio::spawn(async {
        tokio::time::sleep(Duration::from_millis(1)).await;
        Instant::now()
    });
    let started = Instant::now();
    tools.set_session_generation("session-a", 1).await?;
    tokio::time::timeout(Duration::from_millis(200), tick).await??;
    assert!(started.elapsed() < Duration::from_millis(200));
    let old = tokio::time::timeout(Duration::from_secs(1), work).await???;
    assert_eq!(old["status"], "interrupted");
    let new = tools
        .execute_at_generation(
            "execute_code",
            json!({"code":"print('new epoch')"}),
            &context("new"),
            1,
        )
        .await?;
    ok(&new);
    assert_eq!(new["output"], "new epoch\n");
    tools.shutdown().await;
    Ok(())
}

struct ReturnedErrors;
impl ToolExecutor for ReturnedErrors {
    fn schemas(&self) -> Vec<Value> {
        vec![
            json!({"type":"function","function":{"name":"checked_return","parameters":{"type":"object"}}}),
        ]
    }
    fn execute<'a>(
        &'a self,
        _: &'a str,
        arguments: Value,
        _: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move { Ok(json!({"success":false,"error":arguments["error"]})) })
    }
}
#[tokio::test]
async fn ignored_error_valued_successes_still_report_bounded_tool_errors() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let bridge = PythonBridge::new(Arc::new(ReturnedErrors), vec!["checked_return".into()])?;
    let tools =
        LocalTools::open_with_python_bridge(config(&root, &state), None, None, Some(bridge))
            .await?;
    let value = cell(
        &tools,
        r#"from hermes_tools import checked_return
for value in [None, False, 0, '', [], {}]:
    checked_return(error=value)
for i in range(8):
    checked_return(error=str(i) + 'x'*1000)
print('script ignored errors')
"#,
    )
    .await?;
    ok(&value);
    assert_eq!(value["tool_calls_made"], 14);
    let errors = value["tool_errors"].as_array().unwrap();
    assert_eq!(errors.len(), 5);
    for (i, error) in errors.iter().enumerate() {
        assert_eq!(error["tool"], "checked_return");
        assert_eq!(error["error"].as_str().unwrap().chars().count(), 300);
        assert!(error["error"].as_str().unwrap().starts_with(&i.to_string()));
    }
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn oversized_callback_response_reports_uncertain_result_without_retry() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.output_bytes = 1024;
    let bridge = PythonBridge::new(Arc::new(ReturnedErrors), vec!["checked_return".into()])?;
    let tools = LocalTools::open_with_python_bridge(cfg, None, None, Some(bridge)).await?;
    let result = cell(&tools, "from hermes_tools import checked_return\nr=checked_return(error='x'*100000)\nprint(r['success'])").await?;
    ok(&result);
    assert_eq!(result["output"], "False\n");
    assert_eq!(result["tool_calls_made"], 1);
    let error = result["tool_errors"][0]["error"].as_str().unwrap();
    assert!(error.contains("exceeds configured byte limit"));
    assert!(error.contains("do not retry"));
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn real_stdout_stderr_raw_descriptors_are_kept_separate() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let result = cell(&tools, "import sys, os\nprint('normal out')\nos.write(1,b'raw out\\n')\nprint('normal err',file=sys.stderr)\nos.write(2,b'raw err\\n')").await?;
    ok(&result);
    assert_eq!(
        result["output"],
        "normal out\nraw out\n\n--- stderr ---\nnormal err\nraw err\n"
    );
    assert_eq!(result["stdout_bytes_total"], 19);
    assert_eq!(result["stderr_bytes_total"], 19);
    assert_eq!(result["stdout_truncated"], false);
    tools.shutdown().await;
    Ok(())
}

async fn recover_output(tools: &LocalTools, path: &str) -> Result<String> {
    let mut offset = 1;
    let mut text = String::new();
    loop {
        let page = tools
            .execute(
                "read_file",
                json!({"path":path,"offset":offset,"limit":1024}),
                &context("recover"),
            )
            .await?;
        assert_eq!(page["offset_unit"], "utf8_bytes");
        assert_eq!(page["sanitized"], true);
        text.push_str(page["content"].as_str().unwrap());
        if let Some(next) = page["next_offset"].as_u64() {
            assert!(next > offset);
            offset = next;
        } else {
            break;
        }
    }
    Ok(text)
}
#[tokio::test]
async fn head_tail_spill_recovers_exact_sanitized_utf8_without_rerun_and_is_scoped() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.output_bytes = 1024;
    let tools = LocalTools::open(cfg.clone(), None, None).await?;
    let expected = format!("HEAD\n{}TAIL\n", "row 世界\n".repeat(600));
    let result = cell(&tools, "print('HEAD\\n'+'row 世界\\n'*600+'TAIL')").await?;
    ok(&result);
    let text = result["output"].as_str().unwrap();
    assert!(text.starts_with("HEAD\n"));
    assert!(text.ends_with("TAIL\n"));
    assert!(text.len() <= 1024);
    assert!(text.contains("bytes omitted"));
    assert_eq!(result["stdout_truncated"], true);
    assert_eq!(result["stdout_spill_complete"], true);
    assert_eq!(
        result["stdout_bytes_total"].as_u64(),
        Some(expected.len() as u64)
    );
    let path = result["stdout_spill_path"].as_str().unwrap().to_owned();
    assert_eq!(recover_output(&tools, &path).await?, expected);
    let mut other = context("other");
    other.conversation_id = "other-conversation".into();
    assert!(
        tools
            .execute("read_file", json!({"path":path}), &other)
            .await
            .is_err()
    );
    other = context("other");
    other.session_id = "other-session".into();
    assert!(
        tools
            .execute("read_file", json!({"path":path}), &other)
            .await
            .is_err()
    );
    assert!(
        tools
            .execute(
                "write_file",
                json!({"path":path,"content":"not writable"}),
                &context("write")
            )
            .await
            .is_err()
    );
    tools.shutdown().await;
    drop(tools);
    let tools = LocalTools::open(cfg, None, None).await?;
    assert_eq!(recover_output(&tools, &path).await?, expected);
    tools.set_session_generation("session-a", 1).await?;
    assert!(
        tools
            .execute("read_file", json!({"path":path}), &context("new-epoch"))
            .await
            .is_err()
    );
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn ansi_and_pattern_secrets_are_cleaned_in_output_errors_and_private_spills() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.output_bytes = 1024;
    let tools = LocalTools::open(cfg, None, None).await?;
    let token = "sk-synthetic012345678901234567890123456789";
    let code = format!(
        "import sys, os\nprint('\\x1b[31mTraceback context\\x1b[0m')\nprint('MAX_TOKENS=100')\nprint(\"{{'apiKey':'test'}}\")\nprint(({token:?}+'\\n')*100)\nprint('Authorization: Bearer synthetic-private-bearer-token-1234',file=sys.stderr)\nraise ValueError({token:?})"
    );
    let result = cell(&tools, &code).await?;
    assert_eq!(result["status"], "error");
    assert!(!result.to_string().contains(token));
    assert!(
        !result
            .to_string()
            .contains("synthetic-private-bearer-token-1234")
    );
    let output = result["output"].as_str().unwrap();
    assert!(output.contains("Traceback context"));
    assert!(output.contains("ValueError"));
    assert!(!output.contains('\x1b'));
    let path = result["stdout_spill_path"].as_str().unwrap();
    let recovered = recover_output(&tools, path).await?;
    assert!(recovered.contains("MAX_TOKENS=100"));
    assert!(recovered.contains("{'apiKey':'test'}"));
    assert!(!recovered.contains(token));
    let db = rusqlite::Connection::open(&state)?;
    let stored: Vec<u8> = db.query_row(
        "SELECT body FROM local_python_outputs WHERE reference=?1",
        [path],
        |r| r.get(0),
    )?;
    assert!(!String::from_utf8(stored)?.contains(token));
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn import_failure_hints_and_stale_module_reload_warnings_reflect_real_execution() -> Result<()>
{
    let (_dir, root, state) = directories()?;
    fs::write(root.join("project_fixture.py"), "value = 1\n")?;
    let tools = LocalTools::open(config(&root, &state), None, None).await?;
    let missing = cell(&tools, "import module_not_present_in_fixture").await?;
    assert_eq!(missing["status"], "error");
    assert!(
        missing["hint"]
            .as_str()
            .unwrap()
            .contains("standard library")
    );
    let missing = cell(&tools, "from hermes_tools import terminal").await?;
    assert!(missing["hint"].as_str().unwrap().contains("unavailable"));
    let helper = cell(&tools, "json_parse('{}')").await?;
    assert!(
        helper["hint"]
            .as_str()
            .unwrap()
            .contains("from hermes_tools import json_parse")
    );
    let first=cell(&tools,"import sys; sys.path.insert(0,'/work'); import project_fixture; print(project_fixture.value)").await?;
    ok(&first);
    assert_eq!(first["output"], "1\n");
    fs::write(root.join("project_fixture.py"), "value = 222\n")?;
    let stale = cell(&tools, "print(project_fixture.value)").await?;
    ok(&stale);
    assert_eq!(stale["output"], "1\n");
    assert!(stale["warning"].as_str().unwrap().contains("OLD code"));
    assert!(
        stale["warning"]
            .as_str()
            .unwrap()
            .contains("project_fixture")
    );
    let reloaded = cell(
        &tools,
        "import importlib; importlib.reload(project_fixture); print(project_fixture.value)",
    )
    .await?;
    ok(&reloaded);
    assert_eq!(reloaded["output"], "222\n");
    assert!(reloaded.get("warning").is_none());
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn output_capture_caps_and_spill_retention_are_honest_and_bounded() -> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.output_bytes = 1024;
    cfg.timeout = Duration::from_secs(5);
    let tools = LocalTools::open(cfg, None, None).await?;
    let result = cell(&tools, "print('HEAD'+'z'*5050000+'TAIL')").await?;
    ok(&result);
    assert_eq!(result["stdout_capture_capped"], true);
    assert_eq!(result["stdout_spill_complete"], false);
    assert!(result["stdout_bytes_total"].is_null());
    assert!(result["output"].as_str().unwrap().ends_with("TAIL\n"));
    let first = result["stdout_spill_path"].as_str().unwrap().to_owned();
    for _ in 0..17 {
        let value = cell(&tools, "print('x'*2000)").await?;
        ok(&value);
        assert_eq!(value["stdout_spill_complete"], true);
    }
    assert!(
        tools
            .execute("read_file", json!({"path":first}), &context("expired"))
            .await
            .is_err()
    );
    let db = rusqlite::Connection::open(&state)?;
    let (count, bytes): (i64, i64) = db.query_row(
        "SELECT COUNT(*),SUM(length(body)) FROM local_python_outputs",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    assert!(count <= 16);
    assert!(bytes <= 20_000_000);
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn route_capacity_rejects_new_positive_routes_without_evicting_old_generation_fences()
-> Result<()> {
    let (_dir, root, state) = directories()?;
    let mut cfg = config(&root, &state);
    cfg.max_session_routes = 2;
    let tools = LocalTools::open(cfg, None, None).await?;
    tools.set_session_generation("session-a", 0).await?;
    tools.set_session_generation("session-b", 4).await?;
    tools.set_session_generation("session-a", 2).await?;
    // Zero is implicit even with a full positive-tombstone map. A reset that
    // cannot retain its positive fence closes all untracked routes instead.
    tools.set_session_generation("session-c", 0).await?;
    assert!(tools.set_session_generation("session-c", 1).await.is_err());
    assert!(tools.set_session_generation("session-c", 0).await.is_err());
    tools.set_session_generation("session-a", 0).await?;
    assert!(
        tools
            .execute_at_generation(
                "execute_code",
                json!({"code":"print('stale')"}),
                &context("old"),
                0
            )
            .await
            .is_err()
    );
    let good = tools
        .execute_at_generation(
            "execute_code",
            json!({"code":"print('current')"}),
            &context("new"),
            2,
        )
        .await?;
    ok(&good);
    let mut excess = context("over capacity");
    excess.session_id = "session-c".into();
    assert!(
        tools
            .execute(
                "execute_code",
                json!({"code":"print('not admitted')"}),
                &excess
            )
            .await
            .is_err()
    );
    tools.shutdown().await;
    Ok(())
}

#[tokio::test]
async fn full_positive_capacity_reset_cancels_zero_kernel_and_late_callback_approval() -> Result<()>
{
    let (_dir, root, state) = directories()?;
    fs::write(root.join("fixture.txt"), "synthetic fixture")?;
    let mut cfg = config(&root, &state);
    cfg.max_session_routes = 1;
    cfg.write = Permission::Ask;
    cfg.timeout = Duration::from_secs(5);
    let (tx, mut rx) = mpsc::channel(20);
    let hub = InteractionHub::new(Arc::new(Emitter(tx)), Duration::from_secs(5))?;
    let tools = LocalTools::open(cfg, Some(hub.clone()), None).await?;
    tools.set_session_generation("positive-route", 7).await?;
    tools.set_session_generation("session-a", 0).await?;
    let work = {
        let tools = tools.clone();
        tokio::spawn(async move {
            tools.execute_at_generation("execute_code", json!({
                "code":"from hermes_tools import write_file\nwrite_file('must-not-exist','stale')"
            }), &context("old"), 0).await
        })
    };
    resolve(&hub, &request(&mut rx).await, "once").await?;
    let pending_callback = request(&mut rx).await;
    let reset = tokio::time::timeout(
        Duration::from_secs(1),
        tools.set_session_generation("session-a", 1),
    )
    .await?;
    assert!(reset.unwrap_err().to_string().contains("capacity reached"));
    // Even a delayed approval cannot revive the old generation or commit.
    let _ = resolve(&hub, &pending_callback, "once").await;
    let value = tokio::time::timeout(Duration::from_secs(1), work).await???;
    assert_eq!(value["status"], "interrupted", "{value}");
    assert!(!root.join("must-not-exist").exists());
    assert!(
        tools
            .execute_at_generation(
                "read_file",
                json!({"path":"fixture.txt"}),
                &context("old-read"),
                0
            )
            .await
            .is_err()
    );
    assert!(
        tools
            .execute(
                "execute_code",
                json!({"code":"print('not allowed')"}),
                &context("new-cell")
            )
            .await
            .is_err()
    );
    let mut known = context("known-read");
    known.session_id = "positive-route".into();
    let read = tools
        .execute_at_generation("read_file", json!({"path":"fixture.txt"}), &known, 7)
        .await?;
    assert!(read.to_string().contains("synthetic fixture"));
    tools.set_session_generation("positive-route", 8).await?;
    assert!(
        tools
            .execute_at_generation("read_file", json!({"path":"fixture.txt"}), &known, 7)
            .await
            .is_err()
    );
    tools
        .execute_at_generation("read_file", json!({"path":"fixture.txt"}), &known, 8)
        .await?;
    tools.shutdown().await;
    hub.shutdown().await?;
    Ok(())
}
