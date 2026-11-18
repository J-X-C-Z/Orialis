//! Real Core -> controlled loopback HTTP model -> durable SQLite integration.
use anyhow::{Result, ensure};
use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
};
use futures_util::future::BoxFuture;
use hermes_rust_core::{
    ChatRequest, Core, CoreLimits, Provider, RetryableProviderError, Store,
    session_context::{CompressionPolicy, TurnLookup},
    tool_runtime::{ToolExecutor, TurnContext},
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    path::Path,
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

#[derive(Clone)]
struct Gate(Arc<(Mutex<bool>, Condvar)>);
impl Gate {
    fn new() -> Self {
        Self(Arc::new((Mutex::new(false), Condvar::new())))
    }
    fn release(&self) {
        *self.0.0.lock().unwrap() = true;
        self.0.1.notify_all();
    }
    fn wait(&self) {
        let mut done = self.0.0.lock().unwrap();
        while !*done {
            done = self.0.1.wait(done).unwrap();
        }
    }
}
enum Reply {
    Message(Value),
    Partial(Value),
    Fail,
    Wait(Gate, Value),
}
#[derive(Clone)]
struct Model {
    queue: Arc<Mutex<VecDeque<Reply>>>,
    seen: Arc<Mutex<Vec<Value>>>,
}
struct Server {
    model: Model,
    endpoint: String,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Server {
    async fn new(replies: Vec<Reply>) -> Result<Self> {
        let model = Model {
            queue: Arc::new(Mutex::new(replies.into())),
            seen: Arc::new(Mutex::new(vec![])),
        };
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let endpoint = format!("http://{}/v1/chat/completions", listener.local_addr()?);
        let app = Router::new()
            .route("/v1/chat/completions", post(serve))
            .with_state(model.clone());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        Ok(Self {
            model,
            endpoint,
            task,
        })
    }
    fn core(&self, path: &Path, policy: CompressionPolicy, effect: Option<Effect>) -> Result<Core> {
        let mut core = Core::new(
            Store::open(path)?,
            Provider::new(
                self.endpoint.clone(),
                "controlled-session-model".into(),
                None,
                false,
            )?,
        )
        .with_limits(CoreLimits::full())?;
        if let Some(effect) = effect {
            core = core.with_tool_executors(vec![Arc::new(effect)])?;
        }
        core.with_session_context("trusted-owner-alice".into(), policy)
    }
    fn calls(&self) -> usize {
        self.model.seen.lock().unwrap().len()
    }
}
async fn serve(State(model): State<Model>, Json(payload): Json<Value>) -> Response {
    model.seen.lock().unwrap().push(payload);
    let reply = model.queue.lock().unwrap().pop_front();
    let m = match reply {
        Some(Reply::Message(m)) => m,
        Some(Reply::Partial(m)) => {
            return Json(json!({"choices":[{"message":m,"finish_reason":"length"}]}))
                .into_response();
        }
        Some(Reply::Wait(gate, m)) => {
            tokio::task::spawn_blocking(move || gate.wait())
                .await
                .unwrap();
            m
        }
        Some(Reply::Fail) => return StatusCode::SERVICE_UNAVAILABLE.into_response(),
        None => return (StatusCode::BAD_REQUEST, "unexpected extra provider call").into_response(),
    };
    Json(json!({"choices":[{"message":m,"finish_reason":"stop"}]})).into_response()
}
#[derive(Clone)]
struct Effect {
    count: Arc<AtomicUsize>,
    started: Arc<AtomicUsize>,
    gate: Option<Gate>,
}
impl Effect {
    fn new(gate: Option<Gate>) -> Self {
        Self {
            count: Arc::new(AtomicUsize::new(0)),
            started: Arc::new(AtomicUsize::new(0)),
            gate,
        }
    }
}
impl ToolExecutor for Effect {
    fn schemas(&self) -> Vec<Value> {
        vec![
            json!({"type":"function","function":{"name":"write_file","parameters":{"type":"object"}}}),
        ]
    }
    fn execute<'a>(
        &'a self,
        _name: &'a str,
        args: Value,
        _context: &'a TurnContext,
    ) -> BoxFuture<'a, Result<Value>> {
        let effect = self.clone();
        Box::pin(async move {
            tokio::task::spawn_blocking(move || {
                effect.started.fetch_add(1, Ordering::SeqCst);
                if let Some(gate) = effect.gate {
                    gate.wait();
                }
                effect.count.fetch_add(1, Ordering::SeqCst);
                json!({"ok":true,"actual_written":args["text"]})
            })
            .await
            .map_err(Into::into)
        })
    }
}
fn call(id: &str, name: &str, args: Value) -> Value {
    json!({"id":id,"type":"function","function":{"name":name,"arguments":args.to_string()}})
}
fn tools(calls: Vec<Value>) -> Reply {
    Reply::Message(json!({"role":"assistant","content":null,"tool_calls":calls}))
}
fn answer(text: &str) -> Reply {
    Reply::Message(json!({"role":"assistant","content":text}))
}
fn context(input: &str) -> TurnContext {
    TurnContext {
        session_id: "chat".into(),
        conversation_id: "trusted-conversation".into(),
        input_id: input.into(),
    }
}
async fn chat(core: &Core, input: &str, text: &str) -> Result<hermes_rust_core::ChatResponse> {
    core.chat_with_context(
        ChatRequest {
            session_id: "chat".into(),
            message: text.into(),
        },
        context(input),
        None,
    )
    .await
}
async fn wait_until(mut predicate: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(5), async {
        while !predicate() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .unwrap();
}
fn policy() -> CompressionPolicy {
    CompressionPolicy {
        trigger_messages: 8,
        trigger_bytes: usize::MAX,
        retain_turns: 2,
        max_summary_bytes: 2048,
        max_input_bytes: 8 * 1024 * 1024,
        minimum_reduction_percent: 10,
    }
}
fn seed(path: &Path, n: usize) -> Result<String> {
    let mut store = Store::open(path)?;
    let (prompt, _) = store.load_session("chat")?;
    let messages=(0..n).flat_map(|i|[json!({"role":"user","content":format!("Historical decision {i}: cedar. {}","factual detail ".repeat(150))}),json!({"role":"assistant","content":format!("Completed observation {i}. {}","evidence ".repeat(70))})]).collect::<Vec<_>>();
    store.append_turn("chat", 0, &messages)?;
    Ok(prompt)
}

#[tokio::test]
async fn completed_replay_and_restart_verify_input_without_model_or_effect() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let effect = Effect::new(None);
    let server = Server::new(vec![
        tools(vec![call("effect", "write_file", json!({"text":"done"}))]),
        answer("Saved exact final."),
    ])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    let first = chat(&core, "input-1", "Write once").await?;
    assert_eq!(first.answer, "Saved exact final.");
    assert_eq!(first.provider_calls, 2);
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    let raw = core.history("chat".into()).await?;
    assert_eq!(raw.len(), 4);
    assert_eq!(raw[2]["_core_memory_failures"], 0);
    drop(core);
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    let replay = chat(&core, "input-1", "Write once").await?;
    assert_eq!(replay.answer, first.answer);
    assert_eq!(replay.provider_calls, 0);
    assert_eq!(
        core.lookup_completed(
            "chat".into(),
            "input-1".into(),
            json!({"role":"user","content":"Write once"})
        )
        .await?
        .unwrap()
        .answer,
        first.answer
    );
    assert!(chat(&core, "input-1", "different input").await.is_err());
    assert_eq!(server.calls(), 2);
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    assert!(matches!(
        core.cancel_input("chat".into(), "input-1".into()).await?,
        TurnLookup::Completed { .. }
    ));
    assert_eq!(core.reset("chat".into()).await?["generation"], 1);
    assert_eq!(
        chat(&core, "input-1", "Write once").await?.answer,
        first.answer
    );
    assert_eq!(server.calls(), 2);
    assert!(
        Core::new(
            Store::open(&path)?,
            Provider::new(server.endpoint.clone(), "mock".into(), None, true)?
        )
        .with_session_context("another-owner".into(), CompressionPolicy::default())
        .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn retry_before_effect_and_resume_after_effect_keep_one_durable_input() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let effect = Effect::new(None);
    let server = Server::new(vec![
        Reply::Fail,
        tools(vec![call(
            "only-once",
            "write_file",
            json!({"text":"artifact"}),
        )]),
        Reply::Fail,
        answer("Recovered known artifact."),
    ])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    let e = chat(&core, "recover", "Perform task").await.unwrap_err();
    assert!(e.downcast_ref::<RetryableProviderError>().is_some());
    assert!(matches!(
        core.lookup_turn("chat".into(), "recover".into()).await?,
        TurnLookup::Pending {
            uncertain_effects: false,
            ..
        }
    ));
    assert!(chat(&core, "recover", "Perform task").await.is_err());
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    assert!(core.history("chat".into()).await?.is_empty());
    drop(core);
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    let done = chat(&core, "recover", "Perform task").await?;
    assert_eq!(done.answer, "Recovered known artifact.");
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    assert_eq!(core.history("chat".into()).await?.len(), 4);
    let seen = server.model.seen.lock().unwrap();
    assert_eq!(seen.len(), 4);
    assert!(seen[3]["messages"].to_string().contains("actual_written"));
    assert!(
        !seen[3]["messages"]
            .to_string()
            .contains("_core_memory_failures")
    );
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn outer_abort_cancel_and_late_blocking_effect_keep_real_receipt_only() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let gate = Gate::new();
    let effect = Effect::new(Some(gate.clone()));
    let server = Server::new(vec![tools(vec![call(
        "slow",
        "write_file",
        json!({"text":"real effect"}),
    )])])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    let c = core.clone();
    let task = tokio::spawn(async move { chat(&c, "stop-me", "Write slowly").await });
    wait_until(|| effect.started.load(Ordering::SeqCst) == 1).await;
    let cancellation = tokio::time::timeout(
        Duration::from_millis(500),
        core.cancel_input("chat".into(), "stop-me".into()),
    )
    .await??;
    assert!(matches!(
        cancellation,
        TurnLookup::Cancelled {
            uncertain_effects: true,
            ..
        }
    ));
    task.abort();
    let _ = task.await;
    gate.release();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(
                core.lookup_turn("chat".into(), "stop-me".into())
                    .await
                    .unwrap(),
                TurnLookup::Cancelled {
                    uncertain_effects: false,
                    ..
                }
            ) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await?;
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    assert!(core.history("chat".into()).await?.is_empty());
    assert!(chat(&core, "stop-me", "Write slowly").await.is_err());
    assert_eq!(server.calls(), 1);
    let db = hermes_rust_core::private_db::open_private(&path)?;
    let receipt: (String, String) = db.query_row(
        "SELECT status,result_json FROM context_tool_receipts",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    assert_eq!(receipt.0, "completed_after_fence");
    assert!(receipt.1.contains("real effect"));
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn unknown_effect_blocks_retry_while_detached_worker_is_running() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let gate = Gate::new();
    let effect = Effect::new(Some(gate.clone()));
    let server = Server::new(vec![
        tools(vec![call("running", "write_file", json!({"text":"once"}))]),
        answer("Finished after recovery."),
    ])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    let c = core.clone();
    let task = tokio::spawn(async move { chat(&c, "unknown", "Write").await });
    wait_until(|| effect.started.load(Ordering::SeqCst) == 1).await;
    task.abort();
    let _ = task.await;
    assert!(
        chat(&core, "unknown", "Write")
            .await
            .unwrap_err()
            .to_string()
            .contains("uncertain")
    );
    assert_eq!(server.calls(), 1);
    assert_eq!(effect.started.load(Ordering::SeqCst), 1);
    gate.release();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if matches!(
                core.lookup_turn("chat".into(), "unknown".into())
                    .await
                    .unwrap(),
                TurnLookup::Pending {
                    uncertain_effects: false,
                    ..
                }
            ) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await?;
    assert_eq!(
        chat(&core, "unknown", "Write").await?.answer,
        "Finished after recovery."
    );
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    Ok(())
}
#[tokio::test]
async fn real_provider_compaction_preserves_raw_prompt_and_searches_archives() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let original_prompt = seed(&path, 6)?;
    let server = Server::new(vec![
        answer("Earlier decisions chose cedar. Six observations were completed."),
        tools(vec![call(
            "search",
            "session_search",
            json!({"query":"Historical decision 0"}),
        )]),
        answer("Used the persisted summary and source history."),
    ])
    .await?;
    let core = server.core(&path, policy(), None)?;
    let done = chat(&core, "new", "Continue the project").await?;
    assert_eq!(done.provider_calls, 2);
    let raw = core.history("chat".into()).await?;
    assert_eq!(raw.len(), 16);
    assert!(
        raw[0]["content"]
            .as_str()
            .unwrap()
            .starts_with("Historical decision 0")
    );
    let db = hermes_rust_core::private_db::open_private(&path)?;
    let state: (i64, String) = db.query_row(
        "SELECT active_from_seq,summary FROM context_state WHERE session_id='chat'",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    assert_eq!(state.0, 8);
    assert!(state.1.contains("cedar"));
    assert_eq!(
        db.query_row("SELECT prompt FROM sessions WHERE id='chat'", [], |r| {
            r.get::<_, String>(0)
        })?,
        original_prompt
    );
    let seen = server.model.seen.lock().unwrap();
    assert_eq!(seen[0]["tools"], json!([]));
    assert!(
        seen[0]["messages"]
            .to_string()
            .contains("Historical decision 0")
    );
    assert_eq!(seen[1]["messages"][0]["content"], original_prompt);
    assert!(seen[1]["messages"].to_string().contains("REFERENCE ONLY"));
    assert!(
        !seen[1]["messages"]
            .to_string()
            .contains("Historical decision 0")
    );
    assert!(
        seen[1]["messages"]
            .to_string()
            .contains("Historical decision 4")
    );
    assert!(seen[2]["messages"].to_string().contains("runtime"));
    assert!(
        seen[2]["messages"]
            .to_string()
            .contains("Historical decision 0")
    );
    Ok(())
}
#[tokio::test]
async fn failed_summary_preserves_full_context() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    seed(&path, 6)?;
    let server = Server::new(vec![
        Reply::Fail,
        answer("Answered without discarding history."),
    ])
    .await?;
    let core = server.core(&path, policy(), None)?;
    chat(&core, "summary-fail", "Continue").await?;
    let raw = core.history("chat".into()).await?;
    assert_eq!(raw.len(), 14);
    let db = hermes_rust_core::private_db::open_private(&path)?;
    assert_eq!(
        db.query_row(
            "SELECT active_from_seq FROM context_state WHERE session_id='chat'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    assert!(
        server.model.seen.lock().unwrap()[1]["messages"]
            .to_string()
            .contains("Historical decision 0")
    );
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reset_does_not_wait_for_model_and_fences_late_finalization() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let gate = Gate::new();
    let server = Server::new(vec![
        Reply::Wait(
            gate.clone(),
            json!({"role":"assistant","content":"Too late"}),
        ),
        answer("Fresh generation"),
    ])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    let c = core.clone();
    let task = tokio::spawn(async move { chat(&c, "old", "Old request").await });
    wait_until(|| server.calls() == 1).await;
    assert_eq!(
        tokio::time::timeout(Duration::from_millis(500), core.reset("chat".into())).await??["generation"],
        1
    );
    gate.release();
    assert!(task.await?.is_err());
    assert_eq!(
        chat(&core, "fresh", "New request").await?.answer,
        "Fresh generation"
    );
    assert_eq!(core.history("chat".into()).await?.len(), 2);
    assert!(Store::open(&path)?.history("chat")?.is_empty());
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancellation_during_summary_tombstone_blocks_late_begin() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    seed(&path, 6)?;
    let gate = Gate::new();
    let server = Server::new(vec![Reply::Wait(
        gate.clone(),
        json!({"role":"assistant","content":"Completed historical decisions: cedar."}),
    )])
    .await?;
    let core = server.core(&path, policy(), None)?;
    let c = core.clone();
    let task = tokio::spawn(async move { chat(&c, "cancel-before-begin", "Continue").await });
    wait_until(|| server.calls() == 1).await;
    assert!(matches!(
        core.cancel_input("chat".into(), "cancel-before-begin".into())
            .await?,
        TurnLookup::CancelledBeforeStart
    ));
    gate.release();
    assert!(task.await?.is_err());
    assert_eq!(server.calls(), 1);
    assert_eq!(core.history("chat".into()).await?.len(), 12);
    Ok(())
}
#[tokio::test]
async fn reused_tool_id_in_later_round_never_repeats_effect() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let effect = Effect::new(None);
    let server = Server::new(vec![
        tools(vec![call(
            "duplicate",
            "write_file",
            json!({"text":"first"}),
        )]),
        tools(vec![call(
            "duplicate",
            "write_file",
            json!({"text":"second"}),
        )]),
    ])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), Some(effect.clone()))?;
    assert!(
        chat(&core, "collision", "Work")
            .await
            .unwrap_err()
            .to_string()
            .contains("already used")
    );
    assert_eq!(effect.count.load(Ordering::SeqCst), 1);
    assert!(core.history("chat".into()).await?.is_empty());
    ensure!(matches!(
        core.lookup_turn("chat".into(), "collision".into()).await?,
        TurnLookup::Pending {
            uncertain_effects: false,
            ..
        }
    ));
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn core_finalization_cas_never_overwrites_external_history() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let gate = Gate::new();
    let server = Server::new(vec![Reply::Wait(
        gate.clone(),
        json!({"role":"assistant","content":"stale answer"}),
    )])
    .await?;
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    let c = core.clone();
    let task = tokio::spawn(async move { chat(&c, "cas-conflict", "Original request").await });
    wait_until(|| server.calls() == 1).await;
    Store::open(&path)?.append_turn(
        "chat",
        0,
        &[
            json!({"role":"user","content":"external writer"}),
            json!({"role":"assistant","content":"external answer"}),
        ],
    )?;
    gate.release();
    assert!(
        task.await?
            .unwrap_err()
            .to_string()
            .contains("session changed")
    );
    let raw = core.history("chat".into()).await?;
    assert_eq!(raw.len(), 2);
    assert_eq!(raw[0]["content"], "external writer");
    assert!(
        chat(&core, "cas-conflict", "Original request")
            .await
            .unwrap_err()
            .to_string()
            .contains("history changed")
    );
    assert_eq!(server.calls(), 1);
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn core_summary_cas_failure_is_not_silently_ignored() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    seed(&path, 6)?;
    let gate = Gate::new();
    let server = Server::new(vec![Reply::Wait(
        gate.clone(),
        json!({"role":"assistant","content":"Earlier decisions: cedar."}),
    )])
    .await?;
    let core = server.core(&path, policy(), None)?;
    let c = core.clone();
    let task = tokio::spawn(async move { chat(&c, "summary-cas", "Continue").await });
    wait_until(|| server.calls() == 1).await;
    Store::open(&path)?.append_turn(
        "chat",
        12,
        &[
            json!({"role":"user","content":"external newest request"}),
            json!({"role":"assistant","content":"external newest answer"}),
        ],
    )?;
    gate.release();
    assert!(
        task.await?
            .unwrap_err()
            .to_string()
            .contains("session changed while summarizing")
    );
    assert_eq!(server.calls(), 1);
    assert_eq!(core.history("chat".into()).await?.len(), 14);
    let db = hermes_rust_core::private_db::open_private(&path)?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM context_summaries", [], |r| r
            .get::<_, i64>(0))?,
        0
    );
    assert!(matches!(
        core.lookup_turn("chat".into(), "summary-cas".into())
            .await?,
        TurnLookup::Missing
    ));
    Ok(())
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn bounded_summary_timeout_keeps_old_context_and_continues_main_model() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    seed(&path, 6)?;
    let gate = Gate::new();
    let server = Server::new(vec![
        Reply::Wait(
            gate.clone(),
            json!({"role":"assistant","content":"Late summary"}),
        ),
        answer("Used unchanged context."),
    ])
    .await?;
    let core = server
        .core(&path, policy(), None)?
        .with_summary_timeout(Duration::from_millis(25))?;
    let done = chat(&core, "summary-timeout", "Continue").await;
    gate.release();
    assert_eq!(done?.answer, "Used unchanged context.");
    assert_eq!(core.history("chat".into()).await?.len(), 14);
    let seen = server.model.seen.lock().unwrap();
    assert_eq!(seen.len(), 2);
    assert!(
        seen[1]["messages"]
            .to_string()
            .contains("Historical decision 0")
    );
    Ok(())
}
#[tokio::test]
async fn persisted_memory_retry_counter_survives_provider_failure() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let miss = |id: &str| {
        tools(vec![call(
            id,
            "memory",
            json!({"target":"user","action":"remove","old_text":"missing entry"}),
        )])
    };
    let server=Server::new(vec![miss("m1"),miss("m2"),miss("m3"),Reply::Fail,miss("m4"),tools(vec![call("m5","memory",json!({"target":"user","action":"add","content":"must not be saved after counter limit"}))]),answer("Stopped memory retries.")]).await?;
    // A nonempty store gives a genuine no-match consolidation failure.
    let mut store = Store::open(&path)?;
    store.memory_action(&serde_json::from_value(
        json!({"target":"user","action":"add","content":"existing preference"}),
    )?)?;
    drop(store);
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    assert!(chat(&core, "memory-retry", "Remember").await.is_err());
    drop(core);
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    chat(&core, "memory-retry", "Remember").await?;
    assert_eq!(
        Store::open(&path)?.memory("user")?,
        vec!["existing preference"]
    );
    let seen = server.model.seen.lock().unwrap();
    assert!(
        seen.last().unwrap()["messages"]
            .to_string()
            .contains("Memory write retry limit reached")
    );
    Ok(())
}

#[tokio::test]
async fn reset_command_receipt_survives_core_commit_outbound_journal_gap() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let server = Server::new(vec![answer("generation one")]).await?;
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    let first = core
        .reset_for_input("chat".into(), "reset-command".into())
        .await?;
    assert_eq!(first["generation"], 1);
    assert!(matches!(
        core.cancel_input("chat".into(), "reset-command".into())
            .await?,
        TurnLookup::CommandCompleted { generation: 1, .. }
    ));
    drop(core);
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    assert_eq!(
        core.reset_for_input("chat".into(), "reset-command".into())
            .await?,
        first
    );
    chat(&core, "new-message", "New generation").await?;
    assert_eq!(Store::open(&path)?.active_session("chat")?, "chat.1");
    assert!(
        core.reset_for_input("chat".into(), "new-message".into())
            .await
            .is_err()
    );
    assert!(
        chat(&core, "reset-command", "misrouted command")
            .await
            .is_err()
    );
    assert_eq!(
        core.reset_for_input("chat".into(), "second-reset".into())
            .await?["generation"],
        2
    );
    assert_eq!(
        core.reset_for_input("chat".into(), "reset-command".into())
            .await?,
        first
    );
    assert_eq!(Store::open(&path)?.active_session("chat")?, "chat.2");
    assert_eq!(server.calls(), 1);
    assert!(matches!(
        core.lookup_turn("chat".into(), "reset-command".into())
            .await?,
        TurnLookup::CommandCompleted { generation: 1, .. }
    ));
    let db = hermes_rust_core::private_db::open_private(&path)?;
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM context_cancelled_inputs WHERE input_id='reset-command'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    Ok(())
}

#[tokio::test]
async fn length_stopped_summary_never_replaces_context() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    seed(&path, 6)?;
    let server = Server::new(vec![
        Reply::Partial(json!({"role":"assistant","content":"This summary was cut off"})),
        answer("Used intact context"),
    ])
    .await?;
    let core = server.core(&path, policy(), None)?;
    chat(&core, "partial-summary", "Continue").await?;
    let db = hermes_rust_core::private_db::open_private(&path)?;
    assert_eq!(
        db.query_row("SELECT count(*) FROM context_summaries", [], |r| r
            .get::<_, i64>(0))?,
        0
    );
    assert!(
        server.model.seen.lock().unwrap()[1]["messages"]
            .to_string()
            .contains("Historical decision 0")
    );
    Ok(())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn simultaneous_reset_and_stop_have_one_truthful_transactional_outcome() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("core.sqlite");
    let server = Server::new(vec![]).await?;
    let core = server.core(&path, CompressionPolicy::default(), None)?;
    for i in 0..20 {
        let route = format!("reset-race-{i}");
        let input = format!("command-{i}");
        let (reset, cancel) = tokio::join!(
            core.reset_for_input(route.clone(), input.clone()),
            core.cancel_input(route.clone(), input.clone())
        );
        match reset {
            Ok(result) => {
                assert_eq!(result["generation"], 1);
                assert!(matches!(
                    cancel?,
                    TurnLookup::CommandCompleted { generation: 1, .. }
                ));
                assert_eq!(
                    core.reset_for_input(route.clone(), input.clone()).await?,
                    result
                );
            }
            Err(_) => {
                assert!(matches!(cancel?, TurnLookup::CancelledBeforeStart));
                assert!(
                    core.reset_for_input(route.clone(), input.clone())
                        .await
                        .is_err()
                );
            }
        }
    }
    assert_eq!(server.calls(), 0);
    Ok(())
}
