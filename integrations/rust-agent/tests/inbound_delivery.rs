use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
};
use hermes_rust_core::{
    ChatRequest, Core, Provider, Store,
    account_scope::OwnerVerifier,
    delivery::{DeliveryIdentity, DeliveryLimits, DeliveryOutbox, DeliveryStatus},
    inbound_delivery::{ConversationVerifier, InboundDeliveries},
    session_context::CompressionPolicy,
    tool_runtime::{ToolExecutor, TurnContext},
    wire,
};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
};
use tokio::sync::Notify;

#[derive(Default)]
struct FixtureState {
    owner: Mutex<String>,
    deny: AtomicBool,
    calls: Mutex<Vec<Value>>,
    responses: Mutex<VecDeque<Option<Value>>>,
    hold: AtomicBool,
    started: Notify,
    release: Notify,
    hold_verification: AtomicBool,
    verification_started: Notify,
    verification_release: Notify,
}
struct Fixture {
    state: Arc<FixtureState>,
    server: String,
    scope: String,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Fixture {
    async fn new() -> Result<Self> {
        let state = Arc::new(FixtureState::default());
        *state.owner.lock().unwrap() = "fixture-owner".into();
        async fn owner(State(s): State<Arc<FixtureState>>, h: HeaderMap) -> Json<Value> {
            assert_eq!(h["authorization"], "Bearer fixture-token");
            assert!(h.get("x-orialis-device-id").is_none());
            Json(json!({"userId":s.owner.lock().unwrap().clone()}))
        }
        async fn conversation(
            State(s): State<Arc<FixtureState>>,
            Path(c): Path<String>,
            h: HeaderMap,
        ) -> impl IntoResponse {
            assert_eq!(h["authorization"], "Bearer fixture-token");
            assert!(h.get("x-orialis-device-id").is_none());
            if s.hold_verification.load(Ordering::SeqCst) {
                s.verification_started.notify_one();
                s.verification_release.notified().await;
            }
            if s.deny.load(Ordering::SeqCst) || c == "foreign" {
                (StatusCode::NOT_FOUND, Json(json!({"error":"not found"})))
            } else {
                (
                    StatusCode::OK,
                    Json(json!({"items":[],"hasMore":false,"nextCursor":null})),
                )
            }
        }
        async fn model(
            State(s): State<Arc<FixtureState>>,
            Json(request): Json<Value>,
        ) -> impl IntoResponse {
            s.calls.lock().unwrap().push(request.clone());
            s.started.notify_one();
            if s.hold.load(Ordering::SeqCst) {
                s.release.notified().await;
            }
            let response=s.responses.lock().unwrap().pop_front().unwrap_or_else(||Some(json!({"role":"assistant","content":format!("Answer: {}",request["messages"].as_array().unwrap().iter().rev().find(|m|m["role"]=="user").unwrap()["content"].as_str().unwrap())})));
            match response {
                Some(response) => (
                    StatusCode::OK,
                    Json(json!({"choices":[{"message":response,"finish_reason":"stop"}]})),
                ),
                None => (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({"error":"fixture model failed"})),
                ),
            }
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let server = format!("ws://{}/api/v1/agent/ws", listener.local_addr()?);
        let app = Router::new()
            .route("/api/v1/auth/session", get(owner))
            .route("/api/v1/conversations/{id}/messages", get(conversation))
            .route("/v1/chat/completions", post(model))
            .with_state(state.clone());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let scope = OwnerVerifier::new(&server, "TE_ST_Rust", "fixture-token", None)?
            .verify()
            .await?
            .scope();
        Ok(Self {
            state,
            server,
            scope,
            task,
        })
    }
    fn core(&self, path: &std::path::Path) -> Result<Core> {
        let endpoint = self
            .server
            .replace("ws://", "http://")
            .replace("/api/v1/agent/ws", "/v1/chat/completions");
        Core::new(
            Store::open(path)?,
            Provider::new(endpoint, "fixture-model".into(), None, false)?,
        )
        .with_session_context(self.scope.clone(), CompressionPolicy::default())
    }
    async fn inbox(
        &self,
        core: Core,
        path: &std::path::Path,
    ) -> Result<(InboundDeliveries, DeliveryOutbox)> {
        let outbox = DeliveryOutbox::open(
            path,
            DeliveryIdentity::new(&self.scope, &self.server, "TE_ST_Rust", "fixture-token")?,
            DeliveryLimits::default(),
        )
        .await?;
        let inbox = InboundDeliveries::new(
            core,
            outbox.clone(),
            ConversationVerifier::new(
                &self.server,
                "TE_ST_Rust",
                "fixture-token",
                self.scope.clone(),
            )?,
        )
        .await?;
        Ok((inbox, outbox))
    }
    fn calls(&self) -> usize {
        self.state.calls.lock().unwrap().len()
    }
}
fn frame(id: &str, kind: &str, text: &str) -> Value {
    json!({"version":1,"type":kind,"delivery_id":id,"conversation_id":"chat","content":text,"metadata":{"source":"fixture"}})
}

#[tokio::test]
async fn text_uses_existing_chat_context_and_slashes_never_control() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    core.chat(ChatRequest {
        session_id: wire::digest("chat"),
        message: "ordinary prior user message".into(),
    })
    .await?;
    let (inbox, outbox) = fixture
        .inbox(core.clone(), &dir.path().join("out.sqlite"))
        .await?;
    for (n, kind, text) in [
        (0, "cron.delivery", "/new"),
        (1, "proactive.delivery", "/stop"),
        (2, "delivery.send", "plain delivery"),
    ] {
        let f = frame(&format!("in-{n}"), kind, text);
        let admission = inbox.admit(f.clone()).await?;
        assert_eq!(admission.ack["status"], "received");
        assert_eq!(
            inbox
                .inspect(&admission.record.delivery_id)
                .await?
                .unwrap()
                .state,
            "admitted"
        );
        inbox.received(&admission.record.delivery_id).await?;
        inbox.execute(&admission.record.delivery_id).await?;
        let output = outbox
            .inspect(&admission.record.output_id)
            .await?
            .unwrap()
            .request
            .frame()?;
        assert_eq!(output["type"], "proactive.delivery");
        assert!(output.get("reply_to").is_none());
        assert!(output.get("message_id").is_none());
        assert_eq!(inbox.admit(f).await?.ack["status"], "duplicate");
        inbox.received(&admission.record.delivery_id).await?;
        inbox.execute(&admission.record.delivery_id).await?;
    }
    assert_eq!(fixture.calls(), 4);
    assert_eq!(core.session_generation(wire::digest("chat")).await?, 0);
    assert_eq!(core.history(wire::digest("chat")).await?.len(), 8);
    let calls = fixture.state.calls.lock().unwrap();
    assert!(
        calls[2]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["content"] == "ordinary prior user message")
    );
    assert!(
        calls[2]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["content"] == "/new")
    );
    Ok(())
}

#[tokio::test]
async fn exact_fingerprint_durable_ack_scope_and_media_rejections() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let path = dir.path().join("out.sqlite");
    let (inbox, outbox) = fixture.inbox(core.clone(), &path).await?;
    let original = frame("original", "cron.delivery", "text");
    let admitted = inbox.admit(original.clone()).await?;
    assert_eq!(admitted.ack["status"], "received");
    inbox.execute("original").await?;
    assert_eq!(fixture.calls(), 0);
    assert!(inbox.ready(10).await?.is_empty());
    assert_eq!(inbox.pending_receipts(10).await?.len(), 1);
    // The receipt is observed from a separate SQLite connection before execution.
    let db = rusqlite::Connection::open(&path)?;
    assert_eq!(
        db.query_row(
            "SELECT state FROM incoming_deliveries WHERE id='original'",
            [],
            |r| r.get::<_, String>(0)
        )?,
        "admitted"
    );
    drop(db);
    for (key, value) in [
        ("content", json!("changed")),
        ("conversation_id", json!("other")),
        ("metadata", json!({"source":"changed"})),
        ("type", json!("delivery.send")),
    ] {
        let mut changed = original.clone();
        changed[key] = value;
        assert!(inbox.admit(changed).await.is_err());
    }
    for (key, value) in [
        ("owner", json!("forged")),
        ("device_id", json!("XX_YY_Rust")),
        ("conversation_id", json!("foreign")),
        ("attachments", json!([{"id":"media"}])),
    ] {
        let mut changed = frame("rejected", "delivery.send", "text");
        changed[key] = value;
        assert!(inbox.admit(changed).await.is_err());
    }
    assert!(inbox.inspect("rejected").await?.is_none());
    assert_eq!(fixture.calls(), 0);
    drop(inbox);
    drop(outbox);
    let (inbox, _outbox) = fixture.inbox(core, &path).await?;
    assert_eq!(inbox.admit(original).await?.ack["status"], "duplicate");
    *fixture.state.owner.lock().unwrap() = "remapped-owner".into();
    inbox.received("original").await?;
    assert!(inbox.execute("original").await.is_err());
    assert_eq!(fixture.calls(), 0);
    Ok(())
}

#[tokio::test]
async fn model_failure_retries_and_completed_core_receipt_recovers_without_model() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let path = dir.path().join("out.sqlite");
    let (inbox, outbox) = fixture.inbox(core.clone(), &path).await?;
    fixture.state.responses.lock().unwrap().push_back(None);
    inbox
        .admit(frame("retry", "delivery.send", "hello"))
        .await?;
    inbox.received("retry").await?;
    assert!(inbox.execute("retry").await.is_err());
    assert_eq!(inbox.inspect("retry").await?.unwrap().state, "retry");
    inbox.received("retry").await?;
    inbox.execute("retry").await?;
    assert_eq!(fixture.calls(), 2);
    assert_eq!(core.history(wire::digest("chat")).await?.len(), 2);
    let admission = inbox
        .admit(frame("crash", "delivery.send", "receipt before enqueue"))
        .await?;
    let r = admission.record;
    inbox.received("crash").await?;
    core.chat_with_context_at_generation(
        ChatRequest {
            session_id: r.route.clone(),
            message: r.content.clone(),
        },
        TurnContext {
            session_id: r.route.clone(),
            conversation_id: r.conversation_id.clone(),
            input_id: r.input_id.clone(),
        },
        None,
        r.generation,
    )
    .await?;
    assert_eq!(fixture.calls(), 3);
    drop(inbox);
    drop(outbox);
    let (inbox, outbox) = fixture.inbox(core, &path).await?;
    inbox.received("crash").await?;
    inbox.execute("crash").await?;
    assert_eq!(fixture.calls(), 3);
    assert_eq!(inbox.inspect("crash").await?.unwrap().state, "completed");
    assert!(outbox.inspect(&r.output_id).await?.is_some());
    Ok(())
}

#[tokio::test]
async fn retry_budget_and_revoked_output_access_fail_closed() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let (inbox, outbox) = fixture.inbox(core, &dir.path().join("out.sqlite")).await?;
    fixture
        .state
        .responses
        .lock()
        .unwrap()
        .extend([None, None, None]);
    inbox
        .admit(frame("exhausted", "delivery.send", "model unavailable"))
        .await?;
    inbox.received("exhausted").await?;
    for _ in 0..3 {
        assert!(inbox.execute("exhausted").await.is_err());
    }
    inbox.execute("exhausted").await?;
    assert_eq!(fixture.calls(), 3);
    assert_eq!(inbox.inspect("exhausted").await?.unwrap().state, "failed");
    assert!(inbox.ready(10).await?.is_empty());
    assert!(outbox.pending(10).await?.is_empty());
    // Exhaustion fences its receipt and releases the original conversation, so
    // a subsequent input can proceed without resetting unrelated history.
    let next = frame("revoked", "delivery.send", "completed before revocation");
    let row = inbox.admit(next).await?.record;
    inbox.received("revoked").await?;
    inbox.execute("revoked").await?;
    fixture.state.deny.store(true, Ordering::SeqCst);
    assert!(inbox.verify_output(&row.output_id).await.is_err());
    fixture.state.deny.store(false, Ordering::SeqCst);
    *fixture.state.owner.lock().unwrap() = "different-owner".into();
    assert!(inbox.verify_output(&row.output_id).await.is_err());
    assert_eq!(
        outbox.inspect(&row.output_id).await?.unwrap().status,
        DeliveryStatus::Pending
    );
    Ok(())
}

#[tokio::test]
async fn per_conversation_retry_fifo_does_not_starve_other_conversations() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let (inbox, _) = fixture.inbox(core, &dir.path().join("out.sqlite")).await?;
    for n in 0..65 {
        let id = format!("same-{n}");
        inbox
            .admit(frame(&id, "delivery.send", &format!("message {n}")))
            .await?;
        inbox.received(&id).await?;
    }
    let mut other = frame("other", "delivery.send", "independent");
    other["conversation_id"] = json!("other");
    inbox.admit(other).await?;
    inbox.received("other").await?;
    let ready = inbox.ready(4).await?;
    assert_eq!(
        ready
            .iter()
            .map(|r| r.delivery_id.as_str())
            .collect::<Vec<_>>(),
        vec!["same-0", "other"]
    );
    fixture.state.responses.lock().unwrap().push_back(None);
    assert!(inbox.execute("same-0").await.is_err());
    let ready = inbox.ready(4).await?;
    assert_eq!(ready[0].delivery_id, "same-0");
    assert_eq!(ready[1].delivery_id, "other");
    inbox.execute("other").await?;
    inbox.execute("same-0").await?;
    assert_eq!(fixture.calls(), 3);
    let ready = inbox.ready(4).await?;
    assert_eq!(ready.len(), 1);
    assert_eq!(ready[0].delivery_id, "same-1");
    Ok(())
}

#[tokio::test]
async fn cancellation_reset_and_remote_ack_preserve_truth() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let (inbox, outbox) = fixture
        .inbox(core.clone(), &dir.path().join("out.sqlite"))
        .await?;
    let queued = inbox
        .admit(frame("queued", "delivery.send", "not after reset"))
        .await?
        .record;
    core.reset(wire::digest("chat")).await?;
    inbox.received("queued").await?;
    inbox.execute("queued").await?;
    assert_eq!(fixture.calls(), 0);
    assert_eq!(inbox.inspect("queued").await?.unwrap().state, "cancelled");
    assert!(outbox.inspect(&queued.output_id).await?.is_none());
    fixture.state.hold.store(true, Ordering::SeqCst);
    let late = inbox
        .admit(frame("late", "delivery.send", "late response"))
        .await?
        .record;
    let worker = {
        let inbox = inbox.clone();
        tokio::spawn(async move {
            inbox.received("late").await?;
            inbox.execute("late").await
        })
    };
    fixture.state.started.notified().await;
    inbox.cancel_conversation("chat").await?;
    core.cancel(wire::digest("chat")).await?;
    fixture.state.release.notify_one();
    let _ = worker.await?;
    assert!(outbox.inspect(&late.output_id).await?.is_none());
    assert_eq!(inbox.inspect("late").await?.unwrap().state, "cancelled");
    fixture.state.hold.store(false, Ordering::SeqCst);
    let finished = inbox
        .admit(frame("finished", "delivery.send", "answer"))
        .await?
        .record;
    inbox.received("finished").await?;
    inbox.execute("finished").await?;
    assert!(inbox.prepare_send(&finished.output_id).await?.is_some());
    inbox.cancel_conversation("chat").await?;
    assert!(inbox.prepare_send(&finished.output_id).await?.is_none());
    // A late ACK cannot prove a cancelled send never reached the Server. Its
    // status honestly records receipt, not persistence or mobile rendering.
    assert!(outbox.acknowledge(json!({"version":1,"type":"delivery.ack","delivery_id":finished.output_id,"conversation_id":"chat","status":"received"})).await?);
    assert_eq!(
        outbox.inspect(&finished.output_id).await?.unwrap().status,
        DeliveryStatus::Acknowledged {
            status: "received".into()
        }
    );
    assert_eq!(
        inbox.inspect("finished").await?.unwrap().state,
        "cancelled_after_send_attempt"
    );
    Ok(())
}

#[tokio::test]
async fn reset_while_delivery_waits_for_original_route_lock_cannot_start_new_epoch() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let (inbox, outbox) = fixture
        .inbox(core.clone(), &dir.path().join("out.sqlite"))
        .await?;
    fixture.state.hold.store(true, Ordering::SeqCst);
    let original = {
        let core = core.clone();
        tokio::spawn(async move {
            core.chat(ChatRequest {
                session_id: wire::digest("chat"),
                message: "holds route lock".into(),
            })
            .await
        })
    };
    fixture.state.started.notified().await;
    let admitted = inbox
        .admit(frame("waiting", "cron.delivery", "must not cross reset"))
        .await?
        .record;
    inbox.received("waiting").await?;
    let waiting = {
        let inbox = inbox.clone();
        tokio::spawn(async move { inbox.execute("waiting").await })
    };
    for _ in 0..100 {
        if inbox.inspect("waiting").await?.unwrap().state == "running" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    }
    assert_eq!(inbox.inspect("waiting").await?.unwrap().state, "running");
    core.reset(wire::digest("chat")).await?;
    fixture.state.hold.store(false, Ordering::SeqCst);
    fixture.state.release.notify_one();
    assert!(original.await?.is_err());
    assert!(waiting.await?.is_err());
    inbox.execute("waiting").await?;
    assert_eq!(fixture.calls(), 1);
    assert!(outbox.inspect(&admitted.output_id).await?.is_none());
    assert_eq!(inbox.inspect("waiting").await?.unwrap().state, "cancelled");
    Ok(())
}

#[tokio::test]
async fn cancellation_during_remote_admission_and_owned_send_lease_are_fenced() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let core = fixture.core(&dir.path().join("core.sqlite"))?;
    let (inbox, outbox) = fixture.inbox(core, &dir.path().join("out.sqlite")).await?;
    fixture
        .state
        .hold_verification
        .store(true, Ordering::SeqCst);
    let admission = {
        let inbox = inbox.clone();
        tokio::spawn(async move {
            inbox
                .admit(frame(
                    "slow-auth",
                    "delivery.send",
                    "wait for authorization",
                ))
                .await
        })
    };
    fixture.state.verification_started.notified().await;
    inbox.cancel_conversation("chat").await?;
    fixture
        .state
        .hold_verification
        .store(false, Ordering::SeqCst);
    fixture.state.verification_release.notify_one();
    assert!(admission.await?.is_err());
    assert!(inbox.inspect("slow-auth").await?.is_none());
    assert_eq!(fixture.calls(), 0);
    let row = inbox
        .admit(frame("lease", "delivery.send", "send once"))
        .await?
        .record;
    inbox.received("lease").await?;
    inbox.execute("lease").await?;
    inbox.verify_output(&row.output_id).await?;
    let permit = inbox
        .prepare_send(&row.output_id)
        .await?
        .context("send permit absent")?;
    assert_eq!(permit.frame()["delivery_id"], row.output_id);
    let mut cancel = {
        let inbox = inbox.clone();
        tokio::spawn(async move { inbox.cancel_conversation("chat").await })
    };
    // Snapshot-to-send boundary: cancellation cannot commit while the immutable
    // frame lease is held by the writer. Its wait is bounded by host send timeout.
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(20), &mut cancel)
            .await
            .is_err()
    );
    assert_eq!(inbox.inspect("lease").await?.unwrap().state, "completed");
    drop(permit);
    cancel.await??;
    assert_eq!(
        inbox.inspect("lease").await?.unwrap().state,
        "cancelled_after_send_attempt"
    );
    assert_eq!(
        outbox.inspect(&row.output_id).await?.unwrap().status,
        DeliveryStatus::Cancelled
    );
    assert!(inbox.prepare_send(&row.output_id).await?.is_none());
    // Cancellation before reservation gives no permit and no possible-send claim.
    let row = inbox
        .admit(frame("cancel-first", "delivery.send", "never sent"))
        .await?
        .record;
    inbox.received("cancel-first").await?;
    inbox.execute("cancel-first").await?;
    inbox.cancel_conversation("chat").await?;
    assert!(inbox.prepare_send(&row.output_id).await?.is_none());
    assert_eq!(
        inbox.inspect("cancel-first").await?.unwrap().state,
        "cancelled"
    );
    Ok(())
}

struct BlockingTool {
    calls: Arc<AtomicUsize>,
    started: Arc<Notify>,
    release: Arc<Notify>,
}
impl ToolExecutor for BlockingTool {
    fn schemas(&self) -> Vec<Value> {
        vec![
            json!({"type":"function","function":{"name":"fixture_effect","description":"test effect","parameters":{"type":"object","properties":{}}}}),
        ]
    }
    fn execute<'a>(
        &'a self,
        _name: &'a str,
        _args: Value,
        _context: &'a TurnContext,
    ) -> futures_util::future::BoxFuture<'a, Result<Value>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.started.notify_one();
            self.release.notified().await;
            Ok(json!({"ok":true}))
        })
    }
}
#[tokio::test]
async fn uncertain_tool_never_reexecutes_on_reconnect() -> Result<()> {
    let fixture = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let calls = Arc::new(AtomicUsize::new(0));
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let core = fixture
        .core(&dir.path().join("core.sqlite"))?
        .with_tool_executors(vec![Arc::new(BlockingTool {
            calls: calls.clone(),
            started: started.clone(),
            release: release.clone(),
        })])?;
    fixture.state.responses.lock().unwrap().push_back(Some(json!({"role":"assistant","content":null,"tool_calls":[{"id":"once","type":"function","function":{"name":"fixture_effect","arguments":"{}"}}]})));
    let (inbox, outbox) = fixture.inbox(core, &dir.path().join("out.sqlite")).await?;
    inbox
        .admit(frame("effect", "delivery.send", "run effect"))
        .await?;
    let worker = {
        let inbox = inbox.clone();
        tokio::spawn(async move {
            inbox.received("effect").await?;
            inbox.execute("effect").await
        })
    };
    started.notified().await;
    worker.abort();
    let _ = worker.await;
    inbox.received("effect").await?;
    inbox.execute("effect").await?;
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(fixture.calls(), 1);
    assert_eq!(inbox.inspect("effect").await?.unwrap().state, "uncertain");
    assert!(outbox.pending(10).await?.is_empty());
    release.notify_one();
    Ok(())
}

#[test]
#[ignore = "requires ORIALIS_PROTOCOL_PY pointing to pinned original protocol.py"]
fn original_python_parser_accepts_text_receipts_and_proactive_outputs() -> Result<()> {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };
    let protocol = std::env::var("ORIALIS_PROTOCOL_PY")?;
    let fixtures = json!([
        frame("in-cron","cron.delivery","/new"),frame("in-proactive","proactive.delivery","/stop"),frame("in-direct","delivery.send","TEXT"),
        {"version":1,"type":"delivery.ack","delivery_id":"in-cron","conversation_id":"chat","status":"received"},
        {"version":1,"type":"delivery.ack","delivery_id":"in-cron","conversation_id":"chat","status":"duplicate"},
        {"version":1,"type":"proactive.delivery","delivery_id":"delivery_out_abc","conversation_id":"chat","content":"native Core answer"}
    ]);
    let mut child=Command::new("python3").arg("-c").arg(r#"
import importlib.util,json,sys
spec=importlib.util.spec_from_file_location('pinned_protocol',sys.argv[1]); p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
fixtures=json.load(sys.stdin)
for frame in fixtures:
    assert p.parse_message(json.dumps(frame))==frame
media=p.delivery(delivery_id='media',conversation_id='chat',content='caption',attachments=[{'id':'image','name':'image.png','mime_type':'image/png','size':10,'download_url':'https://example.test/image'}])
assert p.parse_message(json.dumps(media))['attachments']
print(json.dumps({'text_fixtures':len(fixtures),'protocol_accepts_delivery_media':True,'adapter_does_not_ingest_delivery_media':True}))
"#).arg(protocol).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(serde_json::to_string(&fixtures)?.as_bytes())?;
    let output = child.wait_with_output()?;
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result: Value = serde_json::from_slice(&output.stdout)?;
    assert_eq!(result["text_fixtures"], 6);
    Ok(())
}

struct ServerChild(std::process::Child);
impl Drop for ServerChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// Real native Agent process, synthetic authenticated WS, real HTTP model. The
/// pinned Server cannot originate delivery inputs, so this is explicitly a peer
/// fixture rather than a fictional actual-Server producer.
#[tokio::test]
async fn native_host_authenticated_ws_ack_controls_reconnect_and_restart() -> Result<()> {
    use futures_util::{SinkExt, StreamExt};
    use std::{
        process::{Command, Stdio},
        time::Duration,
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio_tungstenite::{
        accept_hdr_async,
        tungstenite::{
            Message,
            handshake::server::{Request, Response},
        },
    };
    let model = Fixture::new().await?;
    let dir = tempfile::tempdir()?;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let server = format!("ws://{}/api/v1/agent/ws", listener.local_addr()?);
    let (connected, mut connections) = tokio::sync::mpsc::channel(4);
    let peer = tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            let connected = connected.clone();
            tokio::spawn(async move {
                let mut header = [0u8; 8192];
                let n = loop {
                    let n = stream.peek(&mut header).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    if header[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                        break n;
                    }
                    tokio::task::yield_now().await;
                };
                let text = String::from_utf8_lossy(&header[..n]).to_lowercase();
                if text.contains("upgrade: websocket") {
                    // Tungstenite's Callback trait fixes this HTTP error type;
                    // the test never constructs an error response.
                    #[allow(clippy::result_large_err)]
                    let ws = accept_hdr_async(stream, |request: &Request, response: Response| {
                        assert_eq!(request.headers()["authorization"], "Bearer fixture-token");
                        Ok(response)
                    })
                    .await
                    .unwrap();
                    let _ = connected.send(ws).await;
                } else {
                    assert!(text.contains("authorization: bearer fixture-token"));
                    assert!(!text.contains("x-orialis-device-id:"));
                    stream.read_exact(&mut header[..n]).await.unwrap();
                    let (status, body) = if text.starts_with("get /api/v1/auth/session ") {
                        ("200 OK", json!({"userId":"fixture-owner"}))
                    } else if text.starts_with("get /api/v1/conversations/chat/messages?") {
                        ("200 OK", json!({"items":[],"hasMore":false}))
                    } else {
                        ("404 Not Found", json!({"error":"not found"}))
                    };
                    let body = body.to_string();
                    let response = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    stream.write_all(response.as_bytes()).await.unwrap();
                }
            });
        }
    });
    let db = dir.path().join("agent.sqlite");
    let start = || -> Result<ServerChild> {
        Ok(ServerChild(
            Command::new(
                std::env::var_os("ORIALIS_TEST_AGENT_BINARY")
                    .unwrap_or_else(|| env!("CARGO_BIN_EXE_orialis_agent").into()),
            )
            .args([
                "--server",
                &server,
                "--device",
                "TE_ST_Rust",
                "--token",
                "fixture-token",
                "--endpoint",
                &model
                    .server
                    .replace("ws://", "http://")
                    .replace("/api/v1/agent/ws", "/v1/chat/completions"),
                "--model",
                "fixture-model",
                "--verify-owner",
                "--session-context",
                "--inbound-deliveries",
                "--turn-timeout-secs",
                "5",
                "--db",
            ])
            .arg(&db)
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()?,
        ))
    };
    async fn next(
        ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    ) -> Result<Value> {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(15), ws.next())
                .await?
                .context("closed")??;
            if let Message::Text(text) = message {
                let value: Value = serde_json::from_str(&text)?;
                if value["type"] == "ping" {
                    ws.send(Message::Text(
                        json!({"version":1,"type":"pong"}).to_string().into(),
                    ))
                    .await?;
                    continue;
                }
                return Ok(value);
            }
        }
    }
    async fn handshake(
        ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    ) -> Result<()> {
        let hello = next(ws).await?;
        assert_eq!(hello["type"], "hello");
        assert!(
            hello["capabilities"]
                .as_array()
                .unwrap()
                .contains(&json!("proactive_delivery"))
        );
        ws.send(Message::Text(json!({"version":1,"type":"hello_ack","capabilities":["cron_delivery","proactive_delivery"]}).to_string().into())).await?;
        assert_eq!(next(ws).await?["type"], "capabilities.hello");
        Ok(())
    }
    let mut agent = start()?;
    let mut ws = tokio::time::timeout(Duration::from_secs(10), connections.recv())
        .await?
        .context("no host connection")?;
    handshake(&mut ws).await?;
    let input = frame("ws-in", "cron.delivery", "/new");
    ws.send(Message::Text(input.to_string().into())).await?;
    let ack = next(&mut ws).await?;
    assert_eq!(ack["type"], "delivery.ack");
    assert_eq!(ack["status"], "received");
    let receipt = rusqlite::Connection::open(db.with_extension("delivery.sqlite"))?;
    assert!(
        receipt.query_row(
            "SELECT COUNT(*) FROM incoming_deliveries WHERE id='ws-in'",
            [],
            |r| r.get::<_, i64>(0)
        )? > 0
    );
    drop(receipt);
    let output = next(&mut ws).await?;
    assert_eq!(output["type"], "proactive.delivery");
    assert_eq!(output["content"], "Answer: /new");
    assert!(output.get("reply_to").is_none());
    assert_eq!(model.calls(), 1);
    model.state.started.notified().await;
    // Lose the output ACK, reconnect, and recover the exact output without a
    // second model invocation. The same ID/content then remains a duplicate.
    ws.close(None).await?;
    drop(ws);
    let mut ws = tokio::time::timeout(Duration::from_secs(10), connections.recv())
        .await?
        .context("no reconnect")?;
    handshake(&mut ws).await?;
    let replay = next(&mut ws).await?;
    assert_eq!(replay, output);
    assert_eq!(model.calls(), 1);
    ws.send(Message::Text(json!({"version":1,"type":"delivery.ack","delivery_id":output["delivery_id"],"conversation_id":"chat","status":"received"}).to_string().into())).await?;
    ws.send(Message::Text(input.to_string().into())).await?;
    assert_eq!(next(&mut ws).await?["status"], "duplicate");
    let mut changed = input.clone();
    changed["content"] = json!("different");
    ws.send(Message::Text(changed.to_string().into())).await?;
    assert_eq!(next(&mut ws).await?["status"], "rejected");
    let mut media = frame("media", "delivery.send", "caption");
    media["attachments"] = json!([{"id":"image","name":"image.png","mime_type":"image/png","size":1,"download_url":"https://example.test/image"}]);
    ws.send(Message::Text(media.to_string().into())).await?;
    assert_eq!(next(&mut ws).await?["status"], "rejected");
    let mut foreign = frame("foreign", "delivery.send", "private");
    foreign["conversation_id"] = json!("foreign");
    ws.send(Message::Text(foreign.to_string().into())).await?;
    assert_eq!(next(&mut ws).await?["status"], "rejected");
    // A real host /stop cancels a running delivery, unlike delivery text /stop.
    model.state.hold.store(true, Ordering::SeqCst);
    ws.send(Message::Text(
        frame("stop-late", "delivery.send", "delayed")
            .to_string()
            .into(),
    ))
    .await?;
    assert_eq!(next(&mut ws).await?["status"], "received");
    model.state.started.notified().await;
    ws.send(Message::Text(json!({"version":1,"type":"message.send","message_id":"real-stop","conversation_id":"chat","content":"/stop"}).to_string().into())).await?;
    assert_eq!(next(&mut ws).await?["type"], "message.ack");
    let stop = next(&mut ws).await?;
    assert_eq!(stop["type"], "message.reply");
    assert_eq!(stop["reply_to"], "real-stop");
    ws.send(Message::Text(json!({"version":1,"type":"message.ack","message_id":stop["message_id"],"status":"received"}).to_string().into())).await?;
    model.state.hold.store(false, Ordering::SeqCst);
    model.state.release.notify_one();
    agent.0.kill()?;
    agent.0.wait()?;
    drop(ws);
    drop(agent);
    let _agent = start()?;
    let mut ws = tokio::time::timeout(Duration::from_secs(10), connections.recv())
        .await?
        .context("no restart connection")?;
    handshake(&mut ws).await?;
    ws.send(Message::Text(input.to_string().into())).await?;
    loop {
        let message = next(&mut ws).await?;
        if message["type"] == "delivery.ack" {
            assert_eq!(message["status"], "duplicate");
            break;
        }
        assert_ne!(message["type"], "proactive.delivery");
    }
    let receipt = rusqlite::Connection::open(db.with_extension("delivery.sqlite"))?;
    assert_eq!(
        receipt.query_row(
            "SELECT state FROM incoming_deliveries WHERE id='stop-late'",
            [],
            |r| r.get::<_, String>(0)
        )?,
        "cancelled"
    );
    assert!(model.calls() <= 2);
    peer.abort();
    Ok(())
}
#[tokio::test]
#[ignore = "requires ORIALIS_REAL_SERVER_BIN pointing to pinned real Server"]
async fn real_server_conversation_authorization_and_output_ack_not_persistence() -> Result<()> {
    use hermes_rust_core::delivery::{DeliveryBody, DeliveryKind, DeliveryRequest, DeliveryTarget};
    use std::{
        process::{Command, Stdio},
        time::Duration,
    };
    let binary = std::env::var("ORIALIS_REAL_SERVER_BIN")?;
    let dir = tempfile::tempdir()?;
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    let origin = format!("http://127.0.0.1:{port}");
    let server = format!("ws://127.0.0.1:{port}/api/v1/agent/ws");
    let dbpath = dir.path().join("server.sqlite");
    let _server = ServerChild(
        Command::new(binary)
            .env_clear()
            .env("ORIALIS_HOST", "127.0.0.1")
            .env("ORIALIS_PORT", port.to_string())
            .env("ORIALIS_ENV", "development")
            .env("ORIALIS_DEV_DEVICE_AUTH", "false")
            .env("ORIALIS_PUBLIC_URL", &origin)
            .env(
                "ORIALIS_DATABASE_URL",
                format!("sqlite://{}?mode=rwc", dbpath.display()),
            )
            .env("ORIALIS_UPLOAD_DIR", dir.path().join("uploads"))
            .env("ORIALIS_AGENT_DEVICE_TOKEN", "fixture-token")
            .env("ORIALIS_AGENT_USER_ID", "delivery-owner")
            .env("RUST_LOG", "error")
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()?,
    );
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()?;
    let mut ready = false;
    for _ in 0..100 {
        if http
            .get(format!("{origin}/api/v1/health"))
            .send()
            .await
            .is_ok()
        {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(ready, "Server failed to start");
    let db = rusqlite::Connection::open(dbpath)?;
    db.busy_timeout(Duration::from_secs(5))?;
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('delivery-owner','delivery-owner','no-login'),('other-owner','other-owner','no-login')",[])?;
    db.execute("INSERT INTO conversations(id,user_id,title,created_at,updated_at) VALUES('chat','delivery-owner','Owned','2026-01-01','2026-01-01'),('foreign','other-owner','Foreign','2026-01-01','2026-01-01')",[])?;
    let scope = OwnerVerifier::new(&server, "TE_ST_Rust", "fixture-token", None)?
        .verify()
        .await?
        .scope();
    let verifier =
        ConversationVerifier::new(&server, "TE_ST_Rust", "fixture-token", scope.clone())?;
    verifier.verify("chat").await?;
    assert!(verifier.verify("foreign").await.is_err());
    let outbox = DeliveryOutbox::open(
        dir.path().join("outbox.sqlite"),
        DeliveryIdentity::new(&scope, &server, "TE_ST_Rust", "fixture-token")?,
        DeliveryLimits::default(),
    )
    .await?;
    outbox
        .enqueue(DeliveryRequest {
            delivery_id: "fixture-output".into(),
            target: DeliveryTarget {
                owner: scope,
                device_id: "TE_ST_Rust".into(),
                conversation_id: "chat".into(),
            },
            kind: DeliveryKind::Proactive,
            body: DeliveryBody::text("Synthetic delivery text"),
        })
        .await?;
    let status = outbox
        .send_standalone("fixture-output", "fixture-token", Duration::from_secs(10))
        .await?;
    assert_eq!(
        status,
        DeliveryStatus::Acknowledged {
            status: "received".into()
        }
    );
    // This tests a route the pinned Server really has. It does NOT claim the
    // Server can produce cron/proactive input frames, or persist their outputs.
    assert_eq!(
        db.query_row(
            "SELECT COUNT(*) FROM messages WHERE conversation_id='chat'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    Ok(())
}
