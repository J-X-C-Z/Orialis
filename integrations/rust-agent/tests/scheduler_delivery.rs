// Module integration is deliberately isolated until the host exports/wires it.
pub use hermes_rust_core::{
    ChatRequest, Core, attachments, interactions, session_context, tool_runtime,
};
#[path = "../src/cron_tools.rs"]
mod cron_tools;
#[path = "../src/delivery.rs"]
#[allow(dead_code, reason = "isolated scheduler fixture; delivery pagination is covered by continuation_delivery_cursor")]
mod delivery;
#[path = "../src/private_db.rs"]
mod private_db;
#[path = "../src/scheduler.rs"]
mod scheduler;
use anyhow::Result;
use delivery::*;
use scheduler::*;
use serde_json::json;
use std::sync::{
    Mutex,
    atomic::{AtomicUsize, Ordering},
};
fn identity() -> DeliveryIdentity {
    DeliveryIdentity::new(
        "owner",
        "ws://127.0.0.1:1234/api/v1/agent/ws",
        "AA_Test_Rust",
        "fixture-token",
    )
    .unwrap()
}
fn target() -> DeliveryTarget {
    DeliveryTarget {
        owner: "owner".into(),
        device_id: "AA_Test_Rust".into(),
        conversation_id: "chat".into(),
    }
}
fn job(at: i64) -> JobSpec {
    JobSpec {
        job_id: "job-1".into(),
        target: target(),
        schedule: ScheduleSpec::Once { at_ms: at },
        misfire: MisfirePolicy::CatchUpOnce {
            max_lateness_seconds: None,
        },
        action: JobAction::Generate {
            prompt: "Report today's status".into(),
        },
        delivery_kind: DeliveryKind::Cron,
    }
}
fn ms(value: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(value)
        .unwrap()
        .timestamp_millis()
}
fn cron(expr: &str, tz: &str, fold: DstFold) -> ScheduleSpec {
    ScheduleSpec::Cron {
        expression: expr.into(),
        timezone: tz.into(),
        fold,
    }
}
#[test]
fn cron_calendar_dst_and_limits() {
    let spring = cron("30 2 * * *", "America/New_York", DstFold::First);
    assert_eq!(
        spring.next_after(ms("2026-03-08T00:00:00Z")).unwrap(),
        Some(ms("2026-03-09T06:30:00Z"))
    );
    let fold = cron("30 1 * * *", "America/New_York", DstFold::Both);
    let first = fold
        .next_after(ms("2026-11-01T00:00:00Z"))
        .unwrap()
        .unwrap();
    assert_eq!(first, ms("2026-11-01T05:30:00Z"));
    assert_eq!(
        fold.next_after(first).unwrap(),
        Some(ms("2026-11-01T06:30:00Z"))
    );
    assert_eq!(
        cron("30 1 * * *", "America/New_York", DstFold::First)
            .next_after(first)
            .unwrap(),
        Some(ms("2026-11-02T06:30:00Z"))
    );
    assert_eq!(
        cron("30 1 * * *", "America/New_York", DstFold::Second)
            .next_after(ms("2026-11-01T00:00:00Z"))
            .unwrap(),
        Some(ms("2026-11-01T06:30:00Z"))
    );
    assert_eq!(
        cron("0 9 * * MON-FRI", "Asia/Shanghai", DstFold::First)
            .next_after(ms("2026-11-13T02:00:00Z"))
            .unwrap(),
        Some(ms("2026-11-16T01:00:00Z"))
    );
    assert_eq!(
        cron("0 0 29 FEB *", "UTC", DstFold::First)
            .next_after(ms("2025-01-01T00:00:00Z"))
            .unwrap(),
        Some(ms("2028-02-29T00:00:00Z"))
    );
    assert!(
        cron("0 0 30 FEB *", "UTC", DstFold::First)
            .next_after(ms("2025-01-01T00:00:00Z"))
            .is_err()
    );
    assert!(
        cron("0 0 * * * *", "UTC", DstFold::First)
            .validate()
            .is_err()
    );
    assert!(
        cron("0 0 * * *", "Not/Zone", DstFold::First)
            .validate()
            .is_err()
    );
    assert!(ScheduleSpec::once_rfc3339("2026-11-14T09:00:00").is_err());
    assert_eq!(
        ScheduleSpec::Interval {
            anchor_ms: 1000,
            every_seconds: 2
        }
        .next_after(6999)
        .unwrap(),
        Some(7000)
    );
}
#[derive(Default)]
struct FakeExecutor {
    calls: AtomicUsize,
    receipt: Mutex<Option<DeliveryBody>>,
    unknown: bool,
}
impl ScheduledExecutor for FakeExecutor {
    fn lookup<'a>(&'a self, _: &'a Occurrence) -> DeliveryFuture<'a, ExecutionReceipt> {
        Box::pin(async move {
            Ok(if self.unknown {
                ExecutionReceipt::Unknown
            } else {
                self.receipt
                    .lock()
                    .unwrap()
                    .clone()
                    .map(ExecutionReceipt::Completed)
                    .unwrap_or(ExecutionReceipt::Missing)
            })
        })
    }
    fn execute<'a>(&'a self, _: &'a Occurrence) -> DeliveryFuture<'a, DeliveryBody> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let body = DeliveryBody::text("real fixture callback result");
            *self.receipt.lock().unwrap() = Some(body.clone());
            Ok(body)
        })
    }
    fn cancel<'a>(&'a self, _: &'a Occurrence) -> DeliveryFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
}
#[tokio::test]
async fn durable_claim_and_exact_outbox_handoff() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("jobs.sqlite");
    let schedule = Scheduler::open(&path, identity(), SchedulerLimits::default()).await?;
    schedule.create(job(1000), 0).await?;
    let due = schedule.claim_due(1000, 10).await?;
    assert_eq!(due.len(), 1);
    assert!(schedule.claim_due(1000, 10).await?.is_empty());
    assert_eq!(schedule.list(10, 0).await?.len(), 1);
    assert_eq!(schedule.ready(10).await?.len(), 1);
    assert_eq!(schedule.recovery_page(None, 10).await?.len(), 1);
    let id = due[0].occurrence_id.clone();
    let executor = FakeExecutor::default();
    let result = schedule.execute_occurrence(&id, &executor).await?;
    assert_eq!(result.state, "ready");
    drop(schedule);
    let schedule = Scheduler::open(&path, identity(), SchedulerLimits::default()).await?;
    schedule.execute_occurrence(&id, &executor).await?;
    assert_eq!(executor.calls.load(Ordering::SeqCst), 1);
    let outbox = DeliveryOutbox::open(
        dir.path().join("deliveries.sqlite"),
        identity(),
        DeliveryLimits::default(),
    )
    .await?;
    // Simulate commit in outbox before scheduler's own handoff checkpoint.
    outbox.enqueue(result.delivery_request()?).await?;
    schedule.flush_deliveries(&outbox, 10).await?;
    assert_eq!(outbox.pending(10).await?.len(), 1);
    assert!(outbox.acknowledge(json!({"version":1,"type":"delivery.ack","delivery_id":id,"conversation_id":"wrong","status":"received"})).await.is_err());
    outbox.acknowledge(json!({"version":1,"type":"delivery.ack","delivery_id":id,"conversation_id":"chat","status":"received"})).await?;
    schedule.flush_deliveries(&outbox, 10).await?;
    assert_eq!(
        schedule.occurrence(&id).await?.unwrap().state,
        "acknowledged"
    );
    assert!(outbox.pending(10).await?.is_empty());
    let mut changed = result.delivery_request()?;
    changed.body.content.push('!');
    assert!(outbox.enqueue(changed).await.is_err());
    Ok(())
}
#[tokio::test]
async fn restart_receipt_reconciliation_never_reruns_unknown() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("jobs.sqlite");
    let schedule = Scheduler::open(&path, identity(), SchedulerLimits::default()).await?;
    schedule.create(job(1000), 0).await?;
    let due = schedule.claim_due(1000, 1).await?;
    let key = &due[0].occurrence_id;
    let executor = FakeExecutor {
        unknown: true,
        ..Default::default()
    };
    assert_eq!(
        schedule.execute_occurrence(key, &executor).await?.state,
        "unknown"
    );
    assert_eq!(executor.calls.load(Ordering::SeqCst), 0);
    drop(schedule);
    let schedule = Scheduler::open(&path, identity(), SchedulerLimits::default()).await?;
    let completed = FakeExecutor {
        receipt: Mutex::new(Some(DeliveryBody::text("stored Core final"))),
        ..Default::default()
    };
    assert_eq!(
        schedule
            .execute_occurrence(key, &completed)
            .await?
            .body
            .unwrap()
            .content,
        "stored Core final"
    );
    assert_eq!(completed.calls.load(Ordering::SeqCst), 0);
    Ok(())
}
#[tokio::test]
async fn cancellation_and_misfire_are_persistent() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let schedule = Scheduler::open(
        dir.path().join("jobs.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    let mut spec = job(1000);
    spec.schedule = ScheduleSpec::Interval {
        anchor_ms: 1000,
        every_seconds: 60,
    };
    spec.misfire = MisfirePolicy::Skip { grace_seconds: 10 };
    schedule.create(spec, 0).await?;
    assert!(schedule.claim_due(3_600_000, 10).await?.is_empty());
    assert_eq!(
        schedule.get("job-1").await?.unwrap().next_fire_ms,
        Some(3_601_000)
    );
    let due = schedule.claim_due(3_601_000, 10).await?;
    assert_eq!(due.len(), 1);
    let executor = FakeExecutor::default();
    let body = schedule
        .execute_occurrence(&due[0].occurrence_id, &executor)
        .await?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("out.sqlite"),
        identity(),
        DeliveryLimits::default(),
    )
    .await?;
    schedule.flush_deliveries(&outbox, 10).await?;
    schedule.cancel("job-1").await?;
    schedule.flush_deliveries(&outbox, 10).await?;
    assert_eq!(
        outbox.inspect(&body.occurrence_id).await?.unwrap().status,
        DeliveryStatus::Cancelled
    );
    assert!(schedule.claim_due(99_000_000, 10).await?.is_empty());
    Ok(())
}
#[tokio::test]
async fn owner_lock_bounds_and_scope() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("out.sqlite");
    let outbox = DeliveryOutbox::open(
        &path,
        identity(),
        DeliveryLimits {
            max_records: 1,
            ..Default::default()
        },
    )
    .await?;
    assert!(
        DeliveryOutbox::open(&path, identity(), DeliveryLimits::default())
            .await
            .is_err()
    );
    let req = DeliveryRequest {
        delivery_id: "delivery-1".into(),
        target: target(),
        kind: DeliveryKind::Proactive,
        body: DeliveryBody::text("hello"),
    };
    outbox.enqueue(req.clone()).await?;
    let mut changed = req.clone();
    changed.delivery_id = "delivery-2".into();
    assert!(outbox.enqueue(changed).await.is_err());
    let mut changed = req;
    changed.target.owner = "other".into();
    assert!(outbox.enqueue(changed).await.is_err());
    drop(outbox);
    let wrong = DeliveryIdentity::new(
        "other",
        "ws://127.0.0.1:1234/api/v1/agent/ws",
        "AA_Test_Rust",
        "fixture-token",
    )?;
    assert!(
        DeliveryOutbox::open(&path, wrong, DeliveryLimits::default())
            .await
            .is_err()
    );
    Ok(())
}
#[tokio::test]
async fn actual_core_receipt_rebuilds_result_without_model_retry() -> Result<()> {
    use axum::{Json, Router, routing::post};
    use hermes_rust_core::{Provider, Store};
    let calls = std::sync::Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("http://{}/v1/chat/completions", listener.local_addr()?);
    let app=Router::new().route("/v1/chat/completions",post(move||{let counter=counter.clone();async move{counter.fetch_add(1,Ordering::SeqCst);Json(json!({"choices":[{"message":{"role":"assistant","content":"actual Core stored answer"}}]}))}}));
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let dir = tempfile::tempdir()?;
    let core = Core::new(
        Store::open(&dir.path().join("core.sqlite"))?,
        Provider::new(endpoint, "fixture".into(), None, false)?,
    )
    .with_session_context(
        "owner".into(),
        session_context::CompressionPolicy::default(),
    )?;
    let executor = CoreScheduledExecutor::new(core)?;
    let schedule = Scheduler::open(
        dir.path().join("schedule.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    schedule.create(job(1000), 0).await?;
    let o = schedule.claim_due(1000, 1).await?.remove(0);
    // Core commits before scheduler observes its return. Recovery must find the
    // real Core receipt, not call execute/model a second time.
    let answer = executor.execute(&o).await?;
    assert_eq!(answer.content, "actual Core stored answer");
    let result = schedule
        .execute_occurrence(&o.occurrence_id, &executor)
        .await?;
    assert_eq!(result.body.unwrap(), answer);
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    executor.cancel(&o).await?;
    assert!(matches!(
        executor.lookup(&o).await?,
        ExecutionReceipt::Completed(_)
    ));
    task.abort();
    Ok(())
}
#[tokio::test]
async fn standalone_ws_ignores_unrelated_ack_and_requires_capability() -> Result<()> {
    use futures_util::{SinkExt, StreamExt};
    use std::time::Duration;
    use tokio_tungstenite::tungstenite::Message;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("ws://{}/api/v1/agent/ws", listener.local_addr()?);
    let identity = DeliveryIdentity::new("owner", &url, "AA_Test_Rust", "fixture-token")?;
    let task = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        let hello: serde_json::Value =
            serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(hello["client"], "hermes");
        ws.send(Message::Text(
            json!({"version":1,"type":"hello_ack","capabilities":["cron_delivery"]})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        let request: serde_json::Value =
            serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(request["type"], "cron.delivery");
        for key in ["unrelated", "delivery-one"] {
            ws.send(Message::Text(json!({"version":1,"type":"delivery.ack","delivery_id":key,"conversation_id":"chat","status":"received"}).to_string().into())).await.unwrap();
        }
    });
    let dir = tempfile::tempdir()?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("out.sqlite"),
        identity,
        DeliveryLimits::default(),
    )
    .await?;
    outbox
        .enqueue(DeliveryRequest {
            delivery_id: "delivery-one".into(),
            target: target(),
            kind: DeliveryKind::Cron,
            body: DeliveryBody::text("scheduled"),
        })
        .await?;
    assert_eq!(
        outbox
            .send_standalone("delivery-one", "fixture-token", Duration::from_secs(3))
            .await?,
        DeliveryStatus::Acknowledged {
            status: "received".into()
        }
    );
    task.await?;
    Ok(())
}
#[tokio::test]
#[ignore = "requires the co-launched real server contract harness"]
async fn real_server_delivery_fixture() -> Result<()> {
    let url = std::env::var("DELIVERY_TEST_SERVER")?;
    let identity =
        DeliveryIdentity::new("owner", &url, "TE_ST_Rust", "synthetic-delivery-test-token")?;
    let dir = tempfile::tempdir()?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("delivery.sqlite"),
        identity,
        DeliveryLimits::default(),
    )
    .await?;
    let mut frames = vec![];
    for (i, kind) in [
        DeliveryKind::Cron,
        DeliveryKind::Proactive,
        DeliveryKind::Standalone,
    ]
    .into_iter()
    .enumerate()
    {
        let request = DeliveryRequest {
            delivery_id: format!("real-delivery-{i}"),
            target: DeliveryTarget {
                owner: "owner".into(),
                device_id: "TE_ST_Rust".into(),
                conversation_id: "delivery-conversation".into(),
            },
            kind,
            body: DeliveryBody::text(format!("actual Rust delivery {i}")),
        };
        frames.push(request.frame()?);
        let key = request.delivery_id.clone();
        outbox.enqueue(request).await?;
        assert_eq!(
            outbox
                .send_standalone(
                    &key,
                    "synthetic-delivery-test-token",
                    std::time::Duration::from_secs(5)
                )
                .await?,
            DeliveryStatus::Acknowledged {
                status: "received".into()
            }
        );
    }
    if let Ok(path) = std::env::var("DELIVERY_TEST_FRAMES") {
        std::fs::write(path, serde_json::to_vec_pretty(&frames)?)?;
    }
    Ok(())
}
#[tokio::test]
async fn inbound_delivery_is_durable_text_not_control_and_rejects_changed_id() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("in.sqlite");
    let schedule = Scheduler::open(&path, identity(), SchedulerLimits::default()).await?;
    let frame = json!({"version":1,"type":"cron.delivery","delivery_id":"in-one","conversation_id":"chat","content":"/stop is only text in this scheduled input","metadata":{"source":"fixture"}});
    let (first, ack) = schedule.ingest_inbound(frame.clone(), 1000).await?;
    assert_eq!(ack["status"], "received");
    assert!(matches!(&first.action,JobAction::Generate{prompt} if prompt.starts_with("/stop")));
    drop(schedule);
    let schedule = Scheduler::open(&path, identity(), SchedulerLimits::default()).await?;
    let (again, ack) = schedule.ingest_inbound(frame.clone(), 2000).await?;
    assert_eq!(again.occurrence_id, first.occurrence_id);
    assert_eq!(ack["status"], "duplicate");
    assert!(schedule.claim_due(5000, 10).await?.is_empty());
    let mut changed = frame;
    changed["content"] = json!("different");
    assert!(schedule.ingest_inbound(changed, 3000).await.is_err());
    assert_eq!(schedule.ready(10).await?.len(), 1);
    Ok(())
}
#[tokio::test]
async fn no_overlap_catchup_and_late_ack_truth() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let schedule = Scheduler::open(
        dir.path().join("s.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    let mut spec = job(1000);
    spec.schedule = ScheduleSpec::Interval {
        anchor_ms: 1000,
        every_seconds: 1,
    };
    schedule.create(spec, 0).await?;
    let first = schedule.claim_due(10_000, 10).await?.remove(0);
    assert_eq!(first.scheduled_ms, 1000);
    assert_eq!(
        schedule.get("job-1").await?.unwrap().next_fire_ms,
        Some(11_000)
    );
    assert!(schedule.claim_due(100_000, 10).await?.is_empty());
    schedule
        .execute_occurrence(&first.occurrence_id, &FakeExecutor::default())
        .await?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("d.sqlite"),
        identity(),
        DeliveryLimits::default(),
    )
    .await?;
    schedule.flush_deliveries(&outbox, 10).await?;
    schedule.cancel("job-1").await?;
    schedule.flush_deliveries(&outbox, 10).await?;
    assert!(outbox.acknowledge(json!({"version":1,"type":"delivery.ack","delivery_id":first.occurrence_id,"conversation_id":"chat","status":"received"})).await?);
    assert!(
        schedule
            .confirm_delivery(&first.occurrence_id, &outbox)
            .await?
    );
    assert_eq!(
        schedule
            .occurrence(&first.occurrence_id)
            .await?
            .unwrap()
            .state,
        "acknowledged_after_cancel"
    );
    Ok(())
}
#[tokio::test]
async fn legacy_no_capability_never_sends_delivery() -> Result<()> {
    use futures_util::{SinkExt, StreamExt};
    use std::time::Duration;
    use tokio_tungstenite::tungstenite::Message;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("ws://{}/api/v1/agent/ws", listener.local_addr()?);
    let identity = DeliveryIdentity::new("owner", &url, "AA_Test_Rust", "fixture-token")?;
    let task = tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        ws.next().await.unwrap().unwrap();
        ws.send(Message::Text(
            json!({"version":1,"type":"hello_ack","capabilities":["messages"]})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        assert!(!matches!(ws.next().await, Some(Ok(Message::Text(_)))));
    });
    let dir = tempfile::tempdir()?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("d.sqlite"),
        identity,
        DeliveryLimits::default(),
    )
    .await?;
    outbox
        .enqueue(DeliveryRequest {
            delivery_id: "cap-test".into(),
            target: target(),
            kind: DeliveryKind::Cron,
            body: DeliveryBody::text("must not send"),
        })
        .await?;
    assert!(
        outbox
            .send_standalone("cap-test", "fixture-token", Duration::from_secs(3))
            .await
            .is_err()
    );
    assert_eq!(outbox.pending(10).await?.len(), 1);
    task.await?;
    Ok(())
}
struct ApprovalFrames(tokio::sync::mpsc::UnboundedSender<serde_json::Value>);
impl interactions::FeatureEmitter for ApprovalFrames {
    fn emit<'a>(
        &'a self,
        frame: serde_json::Value,
    ) -> futures_util::future::BoxFuture<'a, Result<()>> {
        Box::pin(async move {
            self.0.send(frame)?;
            Ok(())
        })
    }
}
async fn approval(
    rx: &mut tokio::sync::mpsc::UnboundedReceiver<serde_json::Value>,
) -> serde_json::Value {
    loop {
        let frame = tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();
        if frame["type"] == "approval.request" {
            return frame;
        }
    }
}
fn context(input: &str) -> tool_runtime::TurnContext {
    tool_runtime::TurnContext {
        conversation_id: "chat".into(),
        input_id: input.into(),
        session_id: "session".into(),
    }
}
#[tokio::test]
async fn cron_tools_require_exact_once_approval_and_scope() -> Result<()> {
    use std::{sync::Arc, time::Duration};
    use tool_runtime::ToolExecutor;
    let dir = tempfile::tempdir()?;
    let scheduler = Scheduler::open(
        dir.path().join("s.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    let outbox = DeliveryOutbox::open(
        dir.path().join("o.sqlite"),
        identity(),
        DeliveryLimits::default(),
    )
    .await?;
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let hub =
        interactions::InteractionHub::new(Arc::new(ApprovalFrames(tx)), Duration::from_secs(5))?;
    let executor = Arc::new(FakeExecutor::default());
    let tools = Arc::new(cron_tools::CronTools::new(
        scheduler.clone(),
        outbox,
        executor.clone(),
        hub.clone(),
        "Asia/Shanghai".into(),
    )?);
    assert_eq!(tools.schemas()[0]["function"]["name"], "cronjob_manage");
    let args = json!({"action":"create","schedule":"every 1h","prompt":"Send a factual status summary","timezone":"Asia/Shanghai"});
    let t = tools.clone();
    let denied = args.clone();
    let task = tokio::spawn(async move {
        t.execute("cronjob_manage", denied, &context("deny-create"))
            .await
    });
    let request = approval(&mut rx).await;
    assert!(scheduler.list(10, 0).await?.is_empty());
    hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"chat","decision":"deny"})).await?;
    assert!(task.await?.is_err());
    assert!(scheduler.list(10, 0).await?.is_empty());
    let t = tools.clone();
    let task = tokio::spawn(async move {
        t.execute("cronjob_manage", args, &context("approve-create"))
            .await
    });
    let request = approval(&mut rx).await;
    let visible = request.to_string();
    assert!(
        visible.contains("Asia/Shanghai")
            && visible.contains("factual status")
            && visible.contains("current Orialis conversation chat")
    );
    hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"chat","decision":"once"})).await?;
    let created = task.await??;
    assert_eq!(created["persisted"], true);
    let key = created["job"]["spec"]["job_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut other = context("cross-target");
    other.conversation_id = "not-this-chat".into();
    assert!(
        tools
            .execute(
                "cronjob_manage",
                json!({"action":"remove","job_id":key}),
                &other
            )
            .await
            .is_err()
    );
    assert_eq!(
        tools
            .execute(
                "cronjob_manage",
                json!({"action":"create","owner":"other"}),
                &context("bad-fields")
            )
            .await?["error"],
        "not_supported"
    );
    let t = tools.clone();
    let k = key.clone();
    let task = tokio::spawn(async move {
        t.execute(
            "cronjob_manage",
            json!({"action":"run","job_id":k}),
            &context("manual-run"),
        )
        .await
    });
    let request = approval(&mut rx).await;
    hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"chat","decision":"once"})).await?;
    let run = task.await??;
    assert_eq!(run["generated"], false);
    assert_eq!(executor.calls.load(Ordering::SeqCst), 0);
    let occurrence_id = run["occurrence_id"].as_str().unwrap();
    assert_eq!(
        scheduler.occurrence(occurrence_id).await?.unwrap().state,
        "queued"
    );
    let t = tools.clone();
    let k = key.clone();
    let task = tokio::spawn(async move {
        t.execute(
            "cronjob_manage",
            json!({"action":"cancel","job_id":k}),
            &context("cancel-run"),
        )
        .await
    });
    let request = approval(&mut rx).await;
    hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"chat","decision":"once"})).await?;
    assert_eq!(task.await??["schedule_removed"], false);
    assert!(scheduler.get(&key).await?.unwrap().enabled);
    let t = tools.clone();
    let k = key.clone();
    let task = tokio::spawn(async move {
        t.execute(
            "cronjob_manage",
            json!({"action":"remove","job_id":k}),
            &context("remove-job"),
        )
        .await
    });
    let request = approval(&mut rx).await;
    hub.resolve(&json!({"type":"approval.resolve","request_id":request["request_id"],"conversation_id":"chat","decision":"once"})).await?;
    assert_eq!(task.await??["schedule_removed"], true);
    assert!(!scheduler.get(&key).await?.unwrap().enabled);
    hub.shutdown().await?;
    Ok(())
}
#[tokio::test]
async fn schedule_revision_and_manual_run_are_idempotent() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let scheduler = Scheduler::open(
        dir.path().join("s.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    let first = scheduler.create(job(10_000), 0).await?;
    assert_eq!(first.revision, 1);
    let mut spec = first.spec.clone();
    spec.schedule = ScheduleSpec::Once { at_ms: 20_000 };
    let updated = scheduler.update(1, spec.clone(), 1000).await?;
    assert_eq!(updated.revision, 2);
    assert!(scheduler.update(1, spec, 1000).await.is_err());
    assert!(
        scheduler
            .cancel_at_revision("job-1", 1, true)
            .await
            .is_err()
    );
    let a = scheduler
        .trigger_now("job-1", 2, "same-trusted-turn", 2000)
        .await?;
    let b = scheduler
        .trigger_now("job-1", 2, "same-trusted-turn", 3000)
        .await?;
    assert_eq!(a.occurrence_id, b.occurrence_id);
    assert_eq!(
        scheduler.get("job-1").await?.unwrap().next_fire_ms,
        Some(20_000)
    );
    assert!(
        scheduler
            .trigger_now("job-1", 2, "another-turn", 3000)
            .await
            .is_err()
    );
    Ok(())
}
#[test]
fn cron_tool_schedule_subset_is_precise() {
    assert_eq!(
        cron_tools::parse_schedule("in 30m", "UTC", 1000).unwrap(),
        ScheduleSpec::Once { at_ms: 1_801_000 }
    );
    assert_eq!(
        cron_tools::parse_schedule("30m", "UTC", 1000).unwrap(),
        ScheduleSpec::Interval {
            anchor_ms: 1_801_000,
            every_seconds: 1800
        }
    );
    assert!(cron_tools::parse_schedule("2026-11-01T01:30:00", "America/New_York", 1000).is_err());
    assert!(cron_tools::parse_schedule("2026-03-08T02:30:00", "America/New_York", 1000).is_err());
    assert!(cron_tools::parse_schedule("every monday 9am", "UTC", 1000).is_err());
}
#[tokio::test]
async fn actual_core_timeout_receipt_blocks_a_second_model_call() -> Result<()> {
    use axum::{Json, Router, routing::post};
    use hermes_rust_core::{Provider, Store};
    use std::{sync::Arc, time::Duration};
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!("http://{}/v1/chat/completions", listener.local_addr()?);
    let app = Router::new().route(
        "/v1/chat/completions",
        post(move || {
            let counter = counter.clone();
            async move {
                counter.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_secs(1)).await;
                Json(json!({"choices":[{"message":{"role":"assistant","content":"too late"}}]}))
            }
        }),
    );
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let dir = tempfile::tempdir()?;
    let core = Core::new(
        Store::open(&dir.path().join("core.sqlite"))?,
        Provider::new(endpoint, "fixture".into(), None, false)?,
    )
    .with_session_context(
        "owner".into(),
        session_context::CompressionPolicy::default(),
    )?;
    let executor = CoreScheduledExecutor::new(core)?;
    let scheduler = Scheduler::open(
        dir.path().join("s.sqlite"),
        identity(),
        SchedulerLimits {
            execution_timeout: Duration::from_millis(100),
            ..Default::default()
        },
    )
    .await?;
    scheduler.create(job(1000), 0).await?;
    let o = scheduler.claim_due(1000, 1).await?.remove(0);
    assert_eq!(
        scheduler
            .execute_occurrence(&o.occurrence_id, &executor)
            .await?
            .state,
        "unknown"
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        scheduler
            .execute_occurrence(&o.occurrence_id, &executor)
            .await?
            .state,
        "unknown"
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    for o in scheduler.cancel_run("job-1").await? {
        executor.cancel(&o).await?;
    }
    assert!(scheduler.get("job-1").await?.unwrap().enabled);
    task.abort();
    Ok(())
}
struct GateExecutor {
    started: tokio::sync::Notify,
    release: tokio::sync::Notify,
}
impl ScheduledExecutor for GateExecutor {
    fn lookup<'a>(&'a self, _: &'a Occurrence) -> DeliveryFuture<'a, ExecutionReceipt> {
        Box::pin(async { Ok(ExecutionReceipt::Missing) })
    }
    fn execute<'a>(&'a self, _: &'a Occurrence) -> DeliveryFuture<'a, DeliveryBody> {
        Box::pin(async move {
            self.started.notify_one();
            self.release.notified().await;
            Ok(DeliveryBody::text("controlled callback"))
        })
    }
    fn cancel<'a>(&'a self, _: &'a Occurrence) -> DeliveryFuture<'a, ()> {
        Box::pin(async { Ok(()) })
    }
}
#[tokio::test]
async fn cancelled_but_running_callback_still_blocks_overlap() -> Result<()> {
    use std::sync::Arc;
    let dir = tempfile::tempdir()?;
    let scheduler = Scheduler::open(
        dir.path().join("s.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    let mut spec = job(1000);
    spec.schedule = ScheduleSpec::Interval {
        anchor_ms: 1000,
        every_seconds: 1,
    };
    scheduler.create(spec, 0).await?;
    let o = scheduler.claim_due(1000, 1).await?.remove(0);
    let executor = Arc::new(GateExecutor {
        started: tokio::sync::Notify::new(),
        release: tokio::sync::Notify::new(),
    });
    let running = scheduler.clone();
    let e = executor.clone();
    let task = tokio::spawn(async move {
        running
            .execute_occurrence(&o.occurrence_id, e.as_ref())
            .await
    });
    executor.started.notified().await;
    scheduler.cancel_run("job-1").await?;
    assert!(scheduler.claim_due(10_000, 10).await?.is_empty());
    assert!(
        scheduler
            .trigger_now("job-1", 1, "new-manual", 10_000)
            .await
            .is_err()
    );
    executor.release.notify_one();
    assert_eq!(task.await??.state, "cancelled");
    assert_eq!(scheduler.claim_due(10_000, 10).await?.len(), 1);
    Ok(())
}

#[tokio::test]
async fn queued_page_is_not_starved_by_old_reconciliation_rows() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let scheduler = Scheduler::open(
        &dir.path().join("jobs.sqlite"),
        identity(),
        SchedulerLimits::default(),
    )
    .await?;
    for n in 0..70 {
        let mut spec = job(1000);
        spec.job_id = format!("old-{n:03}");
        scheduler.create(spec, 0).await?;
    }
    let old = scheduler.claim_due(1000, 100).await?;
    assert_eq!(old.len(), 70);
    let unknown = FakeExecutor {
        unknown: true,
        ..Default::default()
    };
    let completed = FakeExecutor::default();
    for (n, occurrence) in old.iter().enumerate() {
        scheduler
            .execute_occurrence(
                &occurrence.occurrence_id,
                if n < 35 { &unknown } else { &completed },
            )
            .await?;
    }
    let mut new = job(2000);
    new.job_id = "new-executable".into();
    scheduler.create(new, 1000).await?;
    let due = scheduler.claim_due(2000, 10).await?;
    assert_eq!(due.len(), 1);
    assert!(
        scheduler
            .ready(64)
            .await?
            .iter()
            .all(|o| o.state != "queued"),
        "fixture must reproduce old host filter starvation"
    );
    let queued = scheduler.queued(64).await?;
    assert_eq!(queued.len(), 1);
    assert_eq!(queued[0].occurrence_id, due[0].occurrence_id);
    assert!(scheduler.queued(0).await.is_err());
    assert!(scheduler.queued(257).await.is_err());
    scheduler
        .execute_occurrence(&queued[0].occurrence_id, &FakeExecutor::default())
        .await?;
    assert!(scheduler.queued(64).await?.is_empty());
    Ok(())
}
