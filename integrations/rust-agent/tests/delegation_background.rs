use anyhow::Result;
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    delegation::{BackgroundCompletion, DelegationConfig, DelegationModel, DelegationRuntime},
    tool_runtime::{ToolExecutor, ToolRouter, TurnContext},
};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
use tokio::sync::{Notify, Semaphore};

struct Model {
    calls: AtomicUsize,
    permits: Semaphore,
    entered: Notify,
    tool: bool,
}
impl Model {
    fn new(permits: usize, tool: bool) -> Arc<Self> {
        Arc::new(Self {
            calls: AtomicUsize::new(0),
            permits: Semaphore::new(permits),
            entered: Notify::new(),
            tool,
        })
    }
}
impl DelegationModel for Model {
    fn route_identity(&self) -> String {
        "background-controlled-v1".into()
    }
    fn complete<'a>(
        &'a self,
        _messages: &'a [Value],
        _tools: &'a [Value],
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.entered.notify_one();
            self.permits.acquire().await?.forget();
            Ok(if self.tool {
                json!({"role":"assistant","tool_calls":[{"id":"effect-1","type":"function","function":{"name":"effect","arguments":"{}"}}]})
            } else {
                json!({"role":"assistant","content":"controlled background result"})
            })
        })
    }
}
fn context() -> TurnContext {
    TurnContext {
        session_id: "root-session".into(),
        conversation_id: "conversation-a".into(),
        input_id: "input-a".into(),
    }
}
fn config() -> DelegationConfig {
    DelegationConfig {
        background_enabled: true,
        ..Default::default()
    }
}
fn open(
    path: &std::path::Path,
    model: Arc<Model>,
    cfg: DelegationConfig,
) -> Result<DelegationRuntime> {
    DelegationRuntime::open(
        path,
        "fixture-owner",
        model,
        Arc::new(ToolRouter::new(vec![])?),
        cfg,
    )
}
fn args() -> Value {
    json!({"background":true,"tasks":[{"goal":"self-contained background task"}]})
}
async fn completed(rt: &DelegationRuntime) -> Result<BackgroundCompletion> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(c) = rt.pending_completions(1).await?.pop() {
                return Ok(c);
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await?
}
async fn wait_calls(model: &Model, n: usize) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while model.calls.load(Ordering::SeqCst) < n {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn background_is_opt_in_and_schema_matches_host_mode() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(0, false);
    let rt = open(
        &d.path().join("disabled.db"),
        model.clone(),
        Default::default(),
    )?;
    assert!(rt.schema()["function"]["parameters"]["properties"]["background"].is_null());
    assert!(rt.dispatch(args(), &context(), 0, "spawn").await.is_err());
    assert_eq!(model.calls.load(Ordering::SeqCst), 0);
    let enabled = open(&d.path().join("enabled.db"), model, config())?;
    assert_eq!(
        enabled.schema()["function"]["parameters"]["properties"]["background"]["type"],
        "boolean"
    );
    Ok(())
}
#[tokio::test]
async fn completion_wake_is_retained_and_follows_durable_publication() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(1, false);
    let rt = open(&d.path().join("wake.db"), model, config())?;
    rt.dispatch(args(), &context(), 0, "wake").await?;
    tokio::time::timeout(Duration::from_secs(2), rt.completion_notified()).await?;
    let rows = rt.pending_completions(1).await?;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].result["results"][0]["status"], "completed");
    assert!(
        tokio::time::timeout(Duration::from_millis(5), rt.completion_notified())
            .await
            .is_err()
    );
    rt.drain().await?;
    Ok(())
}

#[tokio::test]
async fn detached_child_survives_parent_lease_and_handle_is_immutable() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(0, false);
    let rt = open(&d.path().join("bg.db"), model.clone(), config())?;
    let lease = rt
        .prepare_turn(&context(), &json!({"role":"user","content":"parent"}))
        .await?;
    let handle = tokio::time::timeout(
        Duration::from_secs(1),
        rt.dispatch(args(), &context(), 0, "spawn"),
    )
    .await??;
    assert_eq!(handle["status"], "dispatched");
    assert_eq!(handle["mode"], "background");
    drop(lease);
    wait_calls(&model, 1).await;
    assert!(rt.pending_completions(1).await?.is_empty());
    assert_eq!(rt.dispatch(args(), &context(), 0, "spawn").await?, handle);
    model.permits.add_permits(1);
    let completion = completed(&rt).await?;
    assert_eq!(completion.result["results"][0]["status"], "completed");
    assert_eq!(completion.session_id, context().session_id);
    assert_eq!(completion.input_id, context().input_id);
    assert_eq!(rt.dispatch(args(), &context(), 0, "spawn").await?, handle);
    assert!(
        rt.dispatch(
            json!({"background":true,"tasks":[{"goal":"changed"}]}),
            &context(),
            0,
            "spawn"
        )
        .await
        .is_err()
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    assert!(
        rt.mark_completion_enqueued(&completion.notification_id)
            .await?
    );
    assert!(
        rt.mark_completion_enqueued(&completion.notification_id)
            .await?
    );
    assert!(rt.pending_completions(1).await?.is_empty());
    assert_eq!(
        rt.inspect_completion(&completion.notification_id).await?,
        Some(completion.clone())
    );
    assert!(
        rt.completion_is_current(&completion.notification_id)
            .await?
    );
    assert!(rt.inspect_completion("unowned-id").await?.is_none());
    rt.drain().await?;
    Ok(())
}
#[tokio::test]
async fn bounded_capacity_rejects_without_queue_and_stop_is_conversation_scoped() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(0, false);
    let rt = open(
        &d.path().join("capacity.db"),
        model.clone(),
        DelegationConfig {
            max_batch: 1,
            max_concurrent_children: 2,
            ..config()
        },
    )?;
    let a = rt.dispatch(args(), &context(), 0, "a").await?;
    let mut other = context();
    other.session_id = "other-root".into();
    other.conversation_id = "conversation-b".into();
    rt.dispatch(args(), &other, 0, "b").await?;
    wait_calls(&model, 2).await;
    assert!(
        rt.dispatch(args(), &context(), 0, "overflow")
            .await
            .is_err()
    );
    assert!(rt.cancel_conversation("conversation-a").await? >= 1);
    model.permits.add_permits(2);
    let completion = completed(&rt).await?;
    assert_eq!(completion.conversation_id, "conversation-b");
    assert_eq!(completion.result["results"][0]["status"], "completed");
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert_eq!(rt.pending_completions(16).await?.len(), 1);
    let list = rt
        .dispatch(json!({"action":"list"}), &context(), 0, "list")
        .await?;
    assert_eq!(list["subagents"][0]["subagent_id"], a["subagent_ids"][0]);
    assert_eq!(list["subagents"][0]["status"], "interrupted");
    assert!(
        rt.dispatch(
            json!({"action":"stop","subagent_id":a["subagent_ids"][0]}),
            &other,
            0,
            "cross"
        )
        .await
        .is_err()
    );
    rt.drain().await?;
    Ok(())
}
#[tokio::test]
async fn send_permit_serializes_reset_and_invalidates_before_database_wait() -> Result<()> {
    let d = tempfile::tempdir()?;
    let rt = open(&d.path().join("fence.db"), Model::new(1, false), config())?;
    rt.dispatch(args(), &context(), 0, "a").await?;
    let c = completed(&rt).await?;
    rt.mark_completion_enqueued(&c.notification_id).await?;
    let permit = rt
        .prepare_completion_send(&c.notification_id)
        .await?
        .unwrap();
    assert_eq!(permit.completion(), &c);
    let next = rt.clone();
    let reset = tokio::spawn(async move { next.set_session_generation("root-session", 1).await });
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert!(!reset.is_finished());
    assert!(rt.dispatch(args(), &context(), 0, "stale").await.is_err());
    drop(permit);
    reset.await??;
    assert!(!rt.completion_is_current(&c.notification_id).await?);
    assert!(rt.pending_completions(16).await?.is_empty());
    assert!(rt.inspect_completion(&c.notification_id).await?.is_some());
    rt.drain().await?;
    Ok(())
}
#[tokio::test]
async fn continuation_keeps_prior_completion_snapshot_and_uses_new_handle() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Model::new(2, false);
    let rt = open(&d.path().join("continue.db"), model.clone(), config())?;
    let first = rt.dispatch(args(), &context(), 0, "a").await?;
    let c = completed(&rt).await?;
    rt.mark_completion_enqueued(&c.notification_id).await?;
    let second=rt.dispatch(json!({"action":"continue","background":true,"subagent_id":first["subagent_ids"][0],"message":"follow-up"}),&context(),0,"b").await?;
    assert_eq!(first["subagent_ids"], second["subagent_ids"]);
    assert_ne!(first["delegation_id"], second["delegation_id"]);
    let continued = completed(&rt).await?;
    assert_ne!(continued.notification_id, c.notification_id);
    assert_eq!(rt.inspect_completion(&c.notification_id).await?, Some(c));
    assert_eq!(rt.dispatch(args(), &context(), 0, "a").await?, first);
    assert_eq!(model.calls.load(Ordering::SeqCst), 2);
    rt.drain().await?;
    Ok(())
}
#[tokio::test]
async fn drain_cancels_without_suppressing_restart_notice() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("drain.db");
    let model = Model::new(0, false);
    let rt = open(&path, model.clone(), config())?;
    let handle = rt.dispatch(args(), &context(), 0, "a").await?;
    wait_calls(&model, 1).await;
    rt.drain().await?;
    let c = completed(&rt).await?;
    assert_eq!(c.result["results"][0]["status"], "interrupted");
    drop(rt);
    tokio::time::sleep(Duration::from_millis(10)).await;
    let recovered = open(&path, model.clone(), config())?;
    assert_eq!(completed(&recovered).await?, c);
    assert_eq!(
        recovered.dispatch(args(), &context(), 0, "a").await?,
        handle
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    recovered.drain().await?;
    Ok(())
}

struct Effect {
    started: Notify,
    ledger: std::path::PathBuf,
}
impl ToolExecutor for Effect {
    fn schemas(&self) -> Vec<Value> {
        vec![json!({"type":"function","function":{"name":"effect","parameters":{"type":"object"}}})]
    }
    fn execute<'a>(
        &'a self,
        _name: &'a str,
        _args: Value,
        _ctx: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            use std::io::Write;
            let mut f = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&self.ledger)?;
            writeln!(f, "external-effect")?;
            f.sync_all()?;
            self.started.notify_one();
            std::future::pending().await
        })
    }
}
#[test]
#[ignore = "subprocess helper; invoked by crash recovery test"]
fn background_crash_helper() {
    let Some(path) = std::env::var_os("HERMES_BG_CRASH_DB") else {
        return;
    };
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let model = Model::new(1, true);
        let effect = Arc::new(Effect {
            started: Notify::new(),
            ledger: std::env::var_os("HERMES_BG_EFFECT_LEDGER").unwrap().into(),
        });
        let rt = DelegationRuntime::open(
            std::path::Path::new(&path),
            "fixture-owner",
            model,
            Arc::new(ToolRouter::new(vec![effect.clone()]).unwrap()),
            DelegationConfig {
                allowed_tools: std::collections::BTreeSet::from(["effect".into()]),
                capability_scope: Some("synthetic-effect-only".into()),
                ..config()
            },
        )
        .unwrap();
        rt.dispatch(args(), &context(), 0, "crash").await.unwrap();
        effect.started.notified().await;
        std::process::exit(0);
    });
}
#[tokio::test]
async fn process_crash_reports_uncertainty_and_never_replays_external_effect() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("crash.db");
    let ledger = d.path().join("effects.txt");
    let status = std::process::Command::new(std::env::current_exe()?)
        .args([
            "--exact",
            "background_crash_helper",
            "--ignored",
            "--nocapture",
        ])
        .env("HERMES_BG_CRASH_DB", &path)
        .env("HERMES_BG_EFFECT_LEDGER", &ledger)
        .status()?;
    assert!(status.success());
    assert_eq!(std::fs::read_to_string(&ledger)?, "external-effect\n");
    let model = Model::new(10, true);
    let effect = Arc::new(Effect {
        started: Notify::new(),
        ledger: ledger.clone(),
    });
    let rt = DelegationRuntime::open(
        &path,
        "fixture-owner",
        model.clone(),
        Arc::new(ToolRouter::new(vec![effect])?),
        DelegationConfig {
            allowed_tools: std::collections::BTreeSet::from(["effect".into()]),
            capability_scope: Some("synthetic-effect-only".into()),
            ..config()
        },
    )?;
    let c = completed(&rt).await?;
    assert_eq!(c.result["results"][0]["status"], "uncertain");
    assert_eq!(c.result["results"][0]["uncertain_effects"], true);
    let handle = rt.dispatch(args(), &context(), 0, "crash").await?;
    assert_eq!(handle["status"], "dispatched");
    let denied = rt.dispatch(json!({"action":"continue","background":true,"subagent_id":handle["subagent_ids"][0],"message":"retry"}),&context(),0,"unsafe-continue").await.unwrap_err();
    assert!(
        denied.to_string().contains("uncertain effects"),
        "{denied:#}"
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 0);
    assert_eq!(std::fs::read_to_string(&ledger)?, "external-effect\n");
    rt.drain().await?;
    Ok(())
}

#[tokio::test]
async fn changing_background_schema_mode_refuses_continuation() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("mode.db");
    let model = Model::new(1, false);
    let first = open(&path, model.clone(), config())?;
    let handle = first.dispatch(args(), &context(), 0, "a").await?;
    completed(&first).await?;
    first.drain().await?;
    drop(first);
    tokio::time::sleep(Duration::from_millis(10)).await;
    let second = open(&path, model.clone(), Default::default())?;
    let denied=second.dispatch(json!({"action":"continue","subagent_id":handle["subagent_ids"][0],"message":"continue"}),&context(),0,"b").await.unwrap_err();
    assert!(
        denied.to_string().contains("capability scope changed"),
        "{denied:#}"
    );
    assert_eq!(model.calls.load(Ordering::SeqCst), 1);
    second.drain().await?;
    Ok(())
}

struct NestedModel {
    calls: AtomicUsize,
}
impl DelegationModel for NestedModel {
    fn route_identity(&self) -> String {
        "nested-background-fixture".into()
    }
    fn complete<'a>(
        &'a self,
        messages: &'a [Value],
        _tools: &'a [Value],
    ) -> BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let child = messages[1]["content"].as_str().unwrap();
            if child.contains("outer-task") && !messages.iter().any(|m| m["role"] == "tool") {
                Ok(
                    json!({"role":"assistant","tool_calls":[{"id":"nested","type":"function","function":{"name":"delegate_task","arguments":json!({"background":true,"tasks":[{"goal":"inner-task"}]}).to_string()}}]}),
                )
            } else {
                if child.contains("outer-task") {
                    let result: Value = serde_json::from_str(
                        messages.last().unwrap()["content"].as_str().unwrap(),
                    )?;
                    assert_eq!(result["mode"], "inline");
                }
                Ok(json!({"role":"assistant","content":"nested completed"}))
            }
        })
    }
}
#[tokio::test]
async fn nested_background_flag_never_detaches_descendants() -> Result<()> {
    let d = tempfile::tempdir()?;
    let model = Arc::new(NestedModel {
        calls: AtomicUsize::new(0),
    });
    let rt = DelegationRuntime::open(
        &d.path().join("nested.db"),
        "fixture-owner",
        model.clone(),
        Arc::new(ToolRouter::new(vec![])?),
        DelegationConfig {
            max_depth: 2,
            ..config()
        },
    )?;
    rt.dispatch(
        json!({"background":true,"tasks":[{"goal":"outer-task"}]}),
        &context(),
        0,
        "parent",
    )
    .await?;
    let c = completed(&rt).await?;
    assert_eq!(c.result["results"][0]["status"], "completed");
    assert_eq!(model.calls.load(Ordering::SeqCst), 3);
    assert_eq!(rt.pending_completions(16).await?.len(), 1);
    let list = rt
        .dispatch(json!({"action":"list"}), &context(), 0, "list")
        .await?;
    assert_eq!(list["count"], 2);
    rt.drain().await?;
    Ok(())
}

#[tokio::test]
#[ignore = "controlled standalone overhead measurement; run alone in a fresh test process"]
async fn measure_background_delegation_overhead() -> Result<()> {
    fn own_cpu_ns() -> Result<u128> {
        #[cfg(unix)]
        {
            let mut stamp = libc::timespec {
                tv_sec: 0,
                tv_nsec: 0,
            };
            anyhow::ensure!(
                unsafe { libc::clock_gettime(libc::CLOCK_PROCESS_CPUTIME_ID, &mut stamp) } == 0,
                "cannot read own process CPU clock: {}",
                std::io::Error::last_os_error()
            );
            Ok(stamp.tv_sec as u128 * 1_000_000_000 + stamp.tv_nsec as u128)
        }
        #[cfg(not(unix))]
        {
            anyhow::bail!("controlled CPU benchmark requires CLOCK_PROCESS_CPUTIME_ID")
        }
    }
    fn own_memory() -> Result<Value> {
        let status = std::fs::read_to_string("/proc/self/status")?;
        let field = |name: &str| -> Result<u64> {
            let line = status
                .lines()
                .find(|line| line.starts_with(name))
                .ok_or_else(|| anyhow::anyhow!("own /proc/self/status missing {name}"))?;
            Ok(line
                .split_whitespace()
                .nth(1)
                .ok_or_else(|| anyhow::anyhow!("invalid {name}"))?
                .parse()?)
        };
        Ok(
            json!({"pid":std::process::id(), "vm_rss_kib":field("VmRSS:")?,
            "vm_hwm_kib":field("VmHWM:")?, "threads":field("Threads:")?,
            "source":"/proc/self/status", "vm_hwm_scope":"whole test-process lifetime, not a per-phase peak"}),
        )
    }
    fn percentiles(samples: &[u128]) -> Value {
        let mut sorted = samples.to_vec();
        sorted.sort_unstable();
        // Nearest rank. Sorting the copy never reorders recorded requests.
        let rank = |percent: usize| sorted[(sorted.len() * percent).div_ceil(100) - 1];
        json!({"p50":rank(50),"p95":rank(95),"min":sorted[0],"max":sorted[sorted.len()-1],"method":"nearest_rank"})
    }
    let selected = std::env::var("DELEGATION_BENCH_MODE").unwrap_or_else(|_| "both".into());
    let modes: &[&str] = match selected.as_str() {
        "inline" => &["inline"],
        "background" => &["background"],
        "both" => &["inline", "background"],
        _ => anyhow::bail!("DELEGATION_BENCH_MODE must be inline, background, or both"),
    };
    const RUNS: usize = 100;
    for (phase_index, mode) in modes.iter().enumerate() {
        let background = *mode == "background";
        let d = tempfile::tempdir()?;
        let path = d.path().join("delegation-benchmark.db");
        let memory_before_setup = own_memory()?;
        let model = Model::new(RUNS, false);
        // Both modes use the same host capabilities, model, goal, context and
        // bounds. Only the execution-mode argument differs.
        let rt = open(&path, model.clone(), config())?;
        let request =
            json!({"background":background,"tasks":[{"goal":"self-contained background task"}]});
        let memory_before_phase = own_memory()?;
        let phase_cpu_start = own_cpu_ns()?;
        let phase_start = Instant::now();
        let mut dispatch_us = Vec::with_capacity(RUNS);
        let mut completion_us = Vec::with_capacity(RUNS);
        let mut handoff_us = Vec::with_capacity(RUNS);
        let mut raw_samples = Vec::with_capacity(RUNS);
        for i in 0..RUNS {
            let start = Instant::now();
            let returned = rt
                .dispatch(request.clone(), &context(), 0, &format!("call-{i}"))
                .await?;
            let dispatch_return_us = start.elapsed().as_micros();
            let (result, notification_id) = if background {
                // The same bounded SQLite actor + post-commit notification used
                // by the host. No polling timer introduces a minimum latency.
                let completion = loop {
                    if let Some(row) = rt.pending_completions(1).await?.pop() {
                        break row;
                    }
                    rt.completion_notified().await;
                };
                (completion.result, Some(completion.notification_id))
            } else {
                (returned, None)
            };
            let completion_observed_us = start.elapsed().as_micros();
            assert_eq!(
                result["results"][0]["summary"],
                "controlled background result"
            );
            assert_eq!(result["results"][0]["status"], "completed");
            if let Some(id) = notification_id {
                assert!(rt.mark_completion_enqueued(&id).await?);
            }
            let durable_handoff_us = start.elapsed().as_micros();
            dispatch_us.push(dispatch_return_us);
            completion_us.push(completion_observed_us);
            handoff_us.push(durable_handoff_us);
            raw_samples.push(json!({"request_index":i,
                "admission_us":if background { Some(dispatch_return_us) } else { None },
                "dispatch_return_us":dispatch_return_us,"completion_observed_us":completion_observed_us,
                "durable_handoff_us":durable_handoff_us}));
        }
        let phase_wall_ns = phase_start.elapsed().as_nanos();
        let phase_cpu_ns = own_cpu_ns()?
            .checked_sub(phase_cpu_start)
            .expect("monotone process CPU clock");
        let memory_after_phase = own_memory()?;
        assert_eq!(model.calls.load(Ordering::SeqCst), RUNS);
        let sqlite_bytes = std::fs::metadata(&path)?.len();
        let wal_bytes = std::fs::metadata(format!("{}-wal", path.display()))
            .map(|m| m.len())
            .unwrap_or(0);
        let shm_bytes = std::fs::metadata(format!("{}-shm", path.display()))
            .map(|m| m.len())
            .unwrap_or(0);
        rt.drain().await?;
        rt.shutdown().await?;
        let memory_after_teardown = own_memory()?;
        println!(
            "{}",
            json!({
                "benchmark":"delegation_controlled_sqlite","schema_version":2,
                "mode":mode,"selected_mode":selected,"phase_index":phase_index,"runs":RUNS,
                "process_kind":"Rust integration-test binary; not the real Orialis Agent main executable",
                "test_executable":std::env::current_exe()?.file_name().map(|n|n.to_string_lossy().into_owned()),
                "memory_isolation":if modes.len()==1 {"one mode in this process; use a fresh process for every repetition"} else {"both modes share this process; VmHWM is cumulative and must not be compared as independent phase peaks"},
                "controlled_model_calls":RUNS,"same_model_and_task_shape":true,
                "phase_cpu_ns":phase_cpu_ns,"cpu_source":"CLOCK_PROCESS_CPUTIME_ID: own process, all its threads",
                "phase_wall_ns":phase_wall_ns,
                "phase_scope":"100 serialized dispatch/completion requests, assertions, raw-sample collection and background local handoff marking; excludes runtime/database setup and teardown",
                "latency_semantics":{"admission_us":"background detached dispatch return only; null for inline because there is no detached admission stage",
                    "dispatch_return_us":"elapsed from request start until dispatch returns; includes child completion for inline",
                    "completion_observed_us":"elapsed from request start until result observed; background includes durable completion actor read",
                    "durable_handoff_us":"elapsed from request start after assertion and background local handoff marking; not network delivery latency"},
                "dispatch_return_us":percentiles(&dispatch_us),"completion_observed_us":percentiles(&completion_us),
                "durable_handoff_us":percentiles(&handoff_us),"raw_samples_in_request_order":raw_samples,
                "database_bytes_before_teardown":{"sqlite":sqlite_bytes,"wal":wal_bytes,"shm":shm_bytes},
                "memory_before_setup":memory_before_setup,"memory_before_phase":memory_before_phase,
                "memory_after_phase":memory_after_phase,"memory_after_teardown":memory_after_teardown,
                "completion_wait":"bounded actor read + durable completion Notify; no polling timer",
                "external_provider_or_network":false
            })
        );
    }
    Ok(())
}

#[tokio::test]
async fn pending_completion_keyset_pages_stay_stable_when_earlier_rows_are_enqueued() -> Result<()>
{
    let d = tempfile::tempdir()?;
    let model = Model::new(80, false);
    let rt = open(&d.path().join("paging.db"), model, config())?;
    for i in 0..70 {
        rt.dispatch(args(), &context(), 0, &format!("page-{i}"))
            .await?;
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if rt.pending_completions(128).await?.len() == i + 1 {
                    return Ok::<_, anyhow::Error>(());
                }
                rt.completion_notified().await;
            }
        })
        .await??;
    }
    let expected = rt.pending_completions(128).await?;
    assert_eq!(expected.len(), 70);
    assert!(
        expected
            .windows(2)
            .all(|rows| rows[0].notification_id < rows[1].notification_id)
    );
    assert_eq!(rt.pending_completions(7).await?, expected[..7]);
    assert_eq!(rt.pending_completions_after(None, 7).await?, expected[..7]);
    let absent_middle = format!("{}~", expected[20].notification_id);
    assert_eq!(
        rt.pending_completions_after(Some(&absent_middle), 128)
            .await?,
        expected[21..]
    );
    let mut cursor = None;
    let mut seen = Vec::new();
    loop {
        let page = rt.pending_completions_after(cursor.as_deref(), 11).await?;
        if page.is_empty() {
            break;
        }
        cursor = page.last().map(|row| row.notification_id.clone());
        for row in &page {
            assert!(rt.mark_completion_enqueued(&row.notification_id).await?);
        }
        seen.extend(page);
    }
    assert_eq!(seen, expected);
    assert!(rt.pending_completions(128).await?.is_empty());
    assert!(
        rt.pending_completions_after(Some("absent-cursor"), 128)
            .await?
            .is_empty()
    );
    assert!(rt.pending_completions_after(None, 0).await.is_err());
    assert!(rt.pending_completions_after(None, 129).await.is_err());
    assert!(rt.pending_completions_after(Some(""), 1).await.is_err());
    assert!(
        rt.pending_completions_after(Some(&"x".repeat(201)), 1)
            .await
            .is_err()
    );
    rt.drain().await?;
    Ok(())
}
