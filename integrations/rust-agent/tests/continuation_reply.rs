use anyhow::{Context, Result};
use hermes_rust_core::{
    continuation_reply::{
        ContinuationReplyOutbox, ReplyLimits, ReplyRequest, ReplySource, ReplyStatus,
    },
    delivery::{DeliveryIdentity, DeliveryLimits, DeliveryOutbox},
    journal::{Journal, ProvenChatAnchor},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{path::Path, time::Duration};

const SERVER: &str = "ws://127.0.0.1:12345/api/v1/agent/ws";
const DEVICE: &str = "owner_fixture_Rust";
const OWNER: &str = "fixture-owner-scope";
fn hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
fn identity() -> DeliveryIdentity {
    DeliveryIdentity::new(OWNER, SERVER, DEVICE, "fixture-token").unwrap()
}
async fn anchor(root: &str, conversation: &str) -> Result<ProvenChatAnchor> {
    anchor_for(&identity(), root, conversation).await
}
async fn anchor_for(
    identity: &DeliveryIdentity,
    root: &str,
    conversation: &str,
) -> Result<ProvenChatAnchor> {
    let journal = Journal::open(
        Path::new(":memory:"),
        &format!(
            "{}|{}|{}",
            identity.server_url, identity.device_id, identity.owner
        ),
    )
    .await?;
    journal.claim(&format!("chat:{root}"),&json!({"version":1,"type":"message.send","message_id":root,"conversation_id":conversation,"content":"Original user task"})).await?;
    let anchor = journal
        .proven_chat_anchor(root, conversation)
        .await?
        .context("missing original chat proof")?;
    journal.shutdown().await?;
    Ok(anchor)
}

fn make_request(source: &str) -> ReplyRequest {
    let source = ReplySource {
        notification_id: source.into(),
        input_id: format!("parent-continuation-{}", &hash(source)[..40]),
        parent_input_id: "root".into(),
        root_input_id: "root".into(),
        session_id: "session".into(),
        conversation_id: "chat".into(),
        generation: 0,
        outcome_digest: hash("immutable final"),
    };
    ReplyRequest {
        frame: json!({"version":1,"type":"message.reply","message_id":ContinuationReplyOutbox::message_id_for(&identity(),&source.notification_id).unwrap(),"reply_to":"root","conversation_id":"chat","content":"Exact immutable answer"}),
        source,
        artifact_ids: vec![],
    }
}
fn ack(id: &str) -> Value {
    json!({"version":1,"type":"message.ack","message_id":id,"status":"received"})
}
fn rejection(id: &str) -> Value {
    json!({"version":1,"type":"error","code":"REPLY_REJECTED","reply_to":id,"message":"transient or permanent"})
}
async fn open_outbox(
    path: &Path,
    limits: ReplyLimits,
) -> Result<(DeliveryOutbox, ContinuationReplyOutbox)> {
    let delivery = DeliveryOutbox::open(path, identity(), DeliveryLimits::default()).await?;
    let reply = ContinuationReplyOutbox::from_delivery(&delivery, limits).await?;
    Ok((delivery, reply))
}
#[tokio::test]
async fn immutable_duplicate_and_source_anchor_frame_conflicts() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let anchor = anchor("root", "chat").await?;
    let original = make_request("notification");
    assert_eq!(
        outbox.enqueue(original.clone(), &anchor).await?,
        ReplyStatus::Pending
    );
    assert_eq!(
        outbox.enqueue(original.clone(), &anchor).await?,
        ReplyStatus::Pending
    );
    for field in ["message_id", "reply_to", "conversation_id", "type"] {
        let mut changed = original.clone();
        changed.frame[field] = json!("changed");
        assert!(outbox.enqueue(changed, &anchor).await.is_err(), "{field}");
    }
    for change in 0..6 {
        let mut changed = original.clone();
        match change {
            0 => changed.frame["content"] = json!("different"),
            1 => changed.source.generation += 1,
            2 => changed.source.parent_input_id = "other-parent".into(),
            3 => changed.source.session_id = "other-session".into(),
            4 => changed.source.outcome_digest = hash("changed outcome"),
            _ => changed.source.input_id = "stolen-other-input".into(),
        }
        assert!(outbox.enqueue(changed, &anchor).await.is_err());
    }
    let mut impersonated = make_request("other-notification");
    impersonated.frame = original.frame.clone();
    assert!(outbox.enqueue(impersonated, &anchor).await.is_err());
    assert_eq!(
        outbox
            .inspect(&original.message_id())
            .await?
            .unwrap()
            .request,
        original
    );
    Ok(())
}
#[tokio::test]
async fn anchor_requires_real_original_chat_and_same_connection_identity() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let proof = anchor("another-root", "chat").await?;
    assert!(
        outbox
            .enqueue(make_request("notification"), &proof)
            .await
            .is_err()
    );
    let journal = Journal::open(
        Path::new(":memory:"),
        "ws://other.test/ws|other-device|other-owner",
    )
    .await?;
    journal.claim("chat:root",&json!({"version":1,"type":"message.send","message_id":"root","conversation_id":"chat","content":"real input"})).await?;
    let foreign = journal.proven_chat_anchor("root", "chat").await?.unwrap();
    assert!(
        outbox
            .enqueue(make_request("notification"), &foreign)
            .await
            .is_err()
    );
    journal.shutdown().await?;
    Ok(())
}
#[tokio::test]
async fn exact_message_ack_only_and_late_ack_after_suppression() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let request = make_request("ack");
    let id = request.message_id();
    outbox
        .enqueue(request.clone(), &anchor("root", "chat").await?)
        .await?;
    assert!(
        !outbox.acknowledge(ack(&id)).await?,
        "unsent row cannot be acknowledged"
    );
    assert_eq!(outbox.prepare_send(&id, 100).await?, Some(request.frame));
    assert!(outbox.acknowledge(json!({"version":1,"type":"delivery.ack","message_id":id,"delivery_id":id,"status":"received","conversation_id":"chat"})).await.is_err());
    for status in ["accepted", "duplicate", "rejected"] {
        let mut receipt = ack(&id);
        receipt["status"] = json!(status);
        assert!(outbox.acknowledge(receipt).await.is_err());
    }
    assert!(!outbox.acknowledge(ack("unrelated")).await?);
    assert!(outbox.suppress(&id, "conversation stopped").await?);
    assert!(outbox.pending_after(None, 10, 100000).await?.is_empty());
    assert!(outbox.prepare_send(&id, 100000).await?.is_none());
    assert!(outbox.acknowledge(ack(&id)).await?);
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Delivered
    );
    assert!(outbox.acknowledge(ack(&id)).await?);
    assert!(!outbox.suppress(&id, "later stop").await?);
    assert_eq!(
        outbox
            .enqueue(make_request("ack"), &anchor("root", "chat").await?)
            .await?,
        ReplyStatus::Delivered
    );
    Ok(())
}
#[tokio::test]
async fn transient_rejection_retries_same_bytes_and_permanent_is_bounded() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let req = make_request("rejected");
    let id = req.message_id();
    outbox
        .enqueue(req.clone(), &anchor("root", "chat").await?)
        .await?;
    assert!(!outbox.reject(rejection(&id), 0).await?);
    for (attempt, time) in [(1, 100), (2, 1100), (3, 3100)] {
        assert_eq!(
            outbox.prepare_send(&id, time).await?,
            Some(req.frame.clone())
        );
        assert!(outbox.reject(rejection(&id), time).await?);
        assert!(
            outbox.reject(rejection(&id), time).await?,
            "duplicate rejection is harmless"
        );
        let row = outbox.inspect(&id).await?.unwrap();
        assert_eq!(row.attempts, attempt);
        assert_eq!(row.rejection_count, attempt);
        assert!(outbox.prepare_send(&id, time + 1).await?.is_none());
    }
    let row = outbox.inspect(&id).await?.unwrap();
    assert_eq!(row.status, ReplyStatus::Rejected);
    assert!(row.diagnostic.unwrap().contains("permanence unknown"));
    assert!(outbox.prepare_send(&id, 100000).await?.is_none());
    assert!(outbox.pending_after(None, 32, 100000).await?.is_empty());
    assert!(outbox.acknowledge(ack(&id)).await?);
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Delivered
    );
    Ok(())
}
#[tokio::test]
async fn transient_reject_then_success_never_claims_rejected_delivery() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let req = make_request("transient");
    let id = req.message_id();
    outbox
        .enqueue(req.clone(), &anchor("root", "chat").await?)
        .await?;
    outbox.prepare_send(&id, 0).await?;
    assert!(!outbox.reject(rejection("wrong-id"), 0).await?);
    assert!(
        outbox
            .reject(
                json!({"version":1,"type":"error","code":"OTHER","reply_to":id}),
                0
            )
            .await
            .is_err()
    );
    outbox.reject(rejection(&id), 0).await?;
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Pending
    );
    assert_eq!(outbox.prepare_send(&id, 1000).await?, Some(req.frame));
    outbox.acknowledge(ack(&id)).await?;
    outbox.reject(rejection(&id), 1001).await?;
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Delivered
    );
    Ok(())
}
#[tokio::test]
async fn missing_ack_exhaustion_is_uncertain_and_late_ack_resolves() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let req = make_request("lost-ack");
    let id = req.message_id();
    outbox
        .enqueue(req.clone(), &anchor("root", "chat").await?)
        .await?;
    for time in [0, 1000, 3000] {
        assert_eq!(
            outbox.prepare_send(&id, time).await?,
            Some(req.frame.clone())
        );
    }
    assert!(outbox.prepare_send(&id, 7000).await?.is_none());
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Uncertain
    );
    assert!(outbox.prepare_send(&id, i64::MAX).await?.is_none());
    outbox.acknowledge(ack(&id)).await?;
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Delivered
    );
    Ok(())
}
#[tokio::test]
async fn keyset_paging_survives_cursor_removal_and_skips_future_due() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let anchor = anchor("root", "chat").await?;
    for name in ["a", "b", "c", "d"] {
        outbox.enqueue(make_request(name), &anchor).await?;
    }
    let first = outbox.pending_after(None, 2, 0).await?;
    assert_eq!(first.len(), 2);
    let cursor = first[1].request.message_id();
    outbox.suppress(&cursor, "stop cursor only").await?;
    let remaining = outbox.pending_after(Some(&cursor), 2, 0).await?;
    assert_eq!(
        remaining
            .iter()
            .map(|r| r.request.source.notification_id.as_str())
            .collect::<Vec<_>>(),
        ["c", "d"]
    );
    let a = outbox.message_id("a");
    outbox.prepare_send(&a, 0).await?;
    assert_eq!(outbox.pending_after(None, 32, 0).await?.len(), 2);
    assert_eq!(outbox.suppress_conversation("chat", "stop all").await?, 3);
    assert!(outbox.pending_after(None, 32, 10000).await?.is_empty());
    assert!(outbox.acknowledge(ack(&a)).await?);
    assert!(outbox.pending_after(None, 0, 0).await.is_err());
    assert!(outbox.pending_after(None, 257, 0).await.is_err());
    Ok(())
}
#[tokio::test]
async fn retained_capacity_never_frees_dedup_identity() -> Result<()> {
    let limits = ReplyLimits {
        max_records: 2,
        ..ReplyLimits::default()
    };
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), limits).await?;
    let proof = anchor("root", "chat").await?;
    let first = make_request("a");
    let id = first.message_id();
    outbox.enqueue(first.clone(), &proof).await?;
    outbox.prepare_send(&id, 0).await?;
    outbox.acknowledge(ack(&id)).await?;
    outbox.enqueue(make_request("b"), &proof).await?;
    outbox.suppress_conversation("chat", "stop").await?;
    assert!(outbox.enqueue(make_request("c"), &proof).await.is_err());
    assert_eq!(
        outbox.enqueue(first.clone(), &proof).await?,
        ReplyStatus::Delivered
    );
    let mut changed = first;
    changed.frame["content"] = json!("cannot replace old tombstone");
    assert!(outbox.enqueue(changed, &proof).await.is_err());
    Ok(())
}
#[tokio::test]
async fn byte_capacity_counts_terminal_payload_and_limits_validate() -> Result<()> {
    let limits = ReplyLimits {
        max_retained_bytes: 1800,
        ..ReplyLimits::default()
    };
    let (_delivery, reply) = open_outbox(Path::new(":memory:"), limits).await?;
    let proof = anchor("root", "chat").await?;
    let mut first = make_request("a");
    first.frame["content"] = json!("x".repeat(1000));
    let id = first.message_id();
    reply.enqueue(first, &proof).await?;
    reply.suppress(&id, "terminal retained").await?;
    assert!(reply.enqueue(make_request("b"), &proof).await.is_err());
    for limits in [
        ReplyLimits {
            max_attempts: 4,
            ..ReplyLimits::default()
        },
        ReplyLimits {
            base_backoff: Duration::ZERO,
            ..ReplyLimits::default()
        },
        ReplyLimits {
            max_records: 0,
            ..ReplyLimits::default()
        },
    ] {
        assert!(open_outbox(Path::new(":memory:"), limits).await.is_err());
    }
    Ok(())
}
#[tokio::test]
async fn attachment_only_frame_and_local_receipt_ids_are_immutable() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let proof = anchor("root", "chat").await?;
    let mut req = make_request("file");
    req.frame["content"] = json!("");
    req.frame["attachments"] = json!([{"id":"remote-file","name":"result.txt","mime_type":"text/plain","size":4,"download_url":"https://server.test/files/remote-file"}]);
    assert!(outbox.enqueue(req.clone(), &proof).await.is_err());
    req.artifact_ids = vec!["durable-local-artifact".into()];
    let mut invalid = req.clone();
    invalid.frame["attachments"][0]["size"] = Value::Null;
    assert!(outbox.enqueue(invalid, &proof).await.is_err());
    outbox.enqueue(req.clone(), &proof).await?;
    let mut altered = req.clone();
    altered.artifact_ids[0] = "other-local-artifact".into();
    assert!(outbox.enqueue(altered, &proof).await.is_err());
    let mut altered = req.clone();
    altered.frame["attachments"][0]["id"] = json!("other-remote-file");
    assert!(outbox.enqueue(altered, &proof).await.is_err());
    assert_eq!(
        outbox.prepare_send(&req.message_id(), 0).await?,
        Some(req.frame)
    );
    Ok(())
}
#[tokio::test]
async fn reopen_preserves_exact_frame_attempts_backoff_and_terminal_identity() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("delivery.sqlite");
    let proof = anchor("root", "chat").await?;
    let req = make_request("reopen");
    let id = req.message_id();
    {
        let (_delivery, outbox) = open_outbox(
            &path,
            ReplyLimits {
                max_attempts: 2,
                ..ReplyLimits::default()
            },
        )
        .await?;
        outbox.enqueue(req.clone(), &proof).await?;
        outbox.prepare_send(&id, 500).await?;
    }
    let (_delivery, outbox) = open_outbox(&path, ReplyLimits::default()).await?;
    let row = outbox.inspect(&id).await?.unwrap();
    assert_eq!(row.request, req);
    assert_eq!(row.attempts, 1);
    assert_eq!(row.next_attempt_at_ms, 1500);
    assert!(outbox.prepare_send(&id, 1499).await?.is_none());
    assert_eq!(
        outbox.prepare_send(&id, 1500).await?,
        Some(req.frame.clone())
    );
    assert!(
        outbox.prepare_send(&id, 3500).await?.is_none(),
        "reopen cannot expand persisted attempt budget"
    );
    assert_eq!(
        outbox.inspect(&id).await?.unwrap().status,
        ReplyStatus::Uncertain
    );
    outbox.acknowledge(ack(&id)).await?;
    drop(outbox);
    drop(_delivery);
    let (_delivery, outbox) = open_outbox(&path, ReplyLimits::default()).await?;
    assert_eq!(outbox.enqueue(req, &proof).await?, ReplyStatus::Delivered);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path)?.permissions().mode() & 0o777,
            0o600
        );
    }
    Ok(())
}
#[test]
fn crash_writer_subprocess() {
    let Ok(path) = std::env::var("CONTINUATION_REPLY_CRASH_FIXTURE") else {
        return;
    };
    let runtime = tokio::runtime::Runtime::new().unwrap();
    runtime.block_on(async {
        let (_delivery, outbox) = open_outbox(Path::new(&path), ReplyLimits::default())
            .await
            .unwrap();
        let req = make_request("crash");
        let id = req.message_id();
        outbox
            .enqueue(req, &anchor("root", "chat").await.unwrap())
            .await
            .unwrap();
        outbox.prepare_send(&id, 10).await.unwrap();
        // Exercise OS teardown without Rust destructors/checkpoint or shutdown.
        std::process::exit(17);
    });
}
#[tokio::test]
async fn abrupt_process_exit_recovers_same_frame_without_any_rerun() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("crash.sqlite");
    let child_path = path.clone();
    let executable = std::env::current_exe()?;
    let status = tokio::task::spawn_blocking(move || {
        std::process::Command::new(executable)
            .args(["--exact", "crash_writer_subprocess", "--nocapture"])
            .env("CONTINUATION_REPLY_CRASH_FIXTURE", child_path)
            .status()
    })
    .await??;
    assert_eq!(status.code(), Some(17));
    let (_delivery, outbox) = open_outbox(&path, ReplyLimits::default()).await?;
    let req = make_request("crash");
    let row = outbox.inspect(&req.message_id()).await?.unwrap();
    assert_eq!(row.attempts, 1);
    assert_eq!(row.request, req);
    assert_eq!(
        outbox.prepare_send(&req.message_id(), 1010).await?,
        Some(req.frame)
    );
    Ok(())
}
#[tokio::test]
async fn owner_server_device_credential_reopen_is_refused() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("identity.sqlite");
    {
        let (_delivery, _outbox) = open_outbox(&path, ReplyLimits::default()).await?;
    }
    for (owner, server, device, token) in [
        ("other", SERVER, DEVICE, "fixture-token"),
        (OWNER, "ws://other.test/ws", DEVICE, "fixture-token"),
        (OWNER, SERVER, "other-device", "fixture-token"),
        (OWNER, SERVER, DEVICE, "other-token"),
    ] {
        assert!(
            DeliveryOutbox::open(
                &path,
                DeliveryIdentity::new(owner, server, device, token)?,
                DeliveryLimits::default()
            )
            .await
            .is_err()
        );
    }
    Ok(())
}

/// Fixture-only overhead sample; no provider, network, uploads, or frozen result
/// files. Run explicitly with --ignored --nocapture on the comparison machine.
#[tokio::test]
#[ignore = "explicit disk overhead measurement"]
async fn benchmark_reply_outbox_overhead() -> Result<()> {
    use std::time::Instant;
    let dir = tempfile::tempdir()?;
    let (_delivery, outbox) =
        open_outbox(&dir.path().join("bench.sqlite"), ReplyLimits::default()).await?;
    let proof = anchor("root", "chat").await?;
    let started_all = Instant::now();
    let cpu_before = process_cpu_us();
    let mut enqueue = Vec::new();
    let mut prepare = Vec::new();
    let mut acknowledge = Vec::new();
    for i in 0..256 {
        let mut req = make_request(&format!("bench-{i:04}"));
        req.frame["content"] = json!("x".repeat(4096));
        let started = Instant::now();
        outbox.enqueue(req, &proof).await?;
        enqueue.push(started.elapsed().as_micros() as u64);
    }
    let mut full_pending = Vec::new();
    for _ in 0..100 {
        let started = Instant::now();
        let page = outbox.pending_after(None, 32, 0).await?;
        assert_eq!(page.len(), 32);
        full_pending.push(started.elapsed().as_micros() as u64);
    }
    for i in 0..256 {
        let id = outbox.message_id(&format!("bench-{i:04}"));
        let started = Instant::now();
        assert!(outbox.prepare_send(&id, 0).await?.is_some());
        prepare.push(started.elapsed().as_micros() as u64);
        let started = Instant::now();
        assert!(outbox.acknowledge(ack(&id)).await?);
        acknowledge.push(started.elapsed().as_micros() as u64);
    }
    let mut pending = Vec::new();
    for _ in 0..256 {
        let started = Instant::now();
        assert!(outbox.pending_after(None, 32, 10000).await?.is_empty());
        pending.push(started.elapsed().as_micros() as u64);
    }
    let wall_us = started_all.elapsed().as_micros();
    let cpu_delta=cpu_before.zip(process_cpu_us()).map(|(before,after)| json!({"user_us":after.0.saturating_sub(before.0),"system_us":after.1.saturating_sub(before.1)}));
    fn summary(samples: Vec<u64>) -> Value {
        let mut sorted = samples.clone();
        sorted.sort_unstable();
        let total: u64 = samples.iter().sum();
        json!({"count":samples.len(),"p50_us":sorted[sorted.len()/2],"p95_us":sorted[sorted.len()*95/100],"max_us":sorted.last(),"mean_us":total as f64/samples.len() as f64,"samples_us":samples})
    }
    println!(
        "{}",
        json!({"fixture":"continuation_reply_private_sqlite_full_sync","payload_bytes":4096,"retained_rows":256,"wall_us":wall_us,"cpu":cpu_delta,"peak_rss_kib":peak_rss_kib(),"enqueue":summary(enqueue),"prepare_send":summary(prepare),"acknowledge":summary(acknowledge),"full_pending_page":summary(full_pending),"empty_pending_page":summary(pending)})
    );
    Ok(())
}

#[tokio::test]
async fn protocol_field_limits_and_identity_changes_fail_closed() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let proof = anchor("root", "chat").await?;
    for mutation in 0..8 {
        let mut req = make_request(&format!("invalid-{mutation}"));
        match mutation {
            0 => req.frame["content"] = json!(" "),
            1 => req.frame["content"] = json!("x".repeat(256 * 1024 + 1)),
            2 => req.frame["metadata"] = json!({"source":"impersonation"}),
            3 => req.frame["version"] = json!(2),
            4 => req.source.outcome_digest = "invalid".into(),
            5 => req.source.generation = -1,
            6 => req.frame["attachments"] = Value::Null,
            _ => {
                req.frame["attachments"] = json!([{"id":"f","name":"x","mime_type":"text/plain","size":u64::MAX,"download_url":"https://test.invalid/f"}]);
                req.artifact_ids = vec!["f".into()];
            }
        }
        assert!(
            outbox.enqueue(req, &proof).await.is_err(),
            "mutation {mutation}"
        );
    }
    assert!(outbox.pending_after(None, 32, 0).await?.is_empty());
    Ok(())
}

#[tokio::test]
async fn concurrent_identical_and_conflicting_enqueue_remain_atomic() -> Result<()> {
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let proof = anchor("root", "chat").await?;
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..32 {
        let outbox = outbox.clone();
        let proof = proof.clone();
        tasks.spawn(async move { outbox.enqueue(make_request("same"), &proof).await });
    }
    while let Some(task) = tasks.join_next().await {
        assert_eq!(task??, ReplyStatus::Pending);
    }
    assert_eq!(outbox.pending_after(None, 32, 0).await?.len(), 1);
    let mut tasks = tokio::task::JoinSet::new();
    for i in 0..32 {
        let outbox = outbox.clone();
        let proof = proof.clone();
        tasks.spawn(async move {
            let mut req = make_request("race");
            req.frame["content"] = json!(format!("candidate {i}"));
            outbox.enqueue(req, &proof).await
        });
    }
    let mut accepted = 0;
    while let Some(task) = tasks.join_next().await {
        if task?.is_ok() {
            accepted += 1;
        }
    }
    assert_eq!(accepted, 1);
    assert_eq!(outbox.pending_after(None, 32, 0).await?.len(), 2);
    Ok(())
}

fn process_cpu_us() -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
        // getrusage initializes the complete output only on success.
        if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
            return None;
        }
        let usage = unsafe { usage.assume_init() };
        let micros = |time: libc::timeval| -> Option<u64> {
            u64::try_from(time.tv_sec)
                .ok()?
                .checked_mul(1_000_000)?
                .checked_add(u64::try_from(time.tv_usec).ok()?)
        };
        Some((micros(usage.ru_utime)?, micros(usage.ru_stime)?))
    }
    #[cfg(not(unix))]
    {
        None
    }
}

#[tokio::test]
async fn caller_cannot_relabel_existing_database_identity() -> Result<()> {
    let (delivery, _) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    for change in 0..3 {
        let mut altered = delivery.clone();
        match change {
            0 => altered.identity.owner = "another-owner".into(),
            1 => altered.identity.server_url = "ws://another.test/ws".into(),
            _ => altered.identity.device_id = "another-device".into(),
        }
        assert!(
            ContinuationReplyOutbox::from_delivery(&altered, ReplyLimits::default())
                .await
                .is_err()
        );
    }
    Ok(())
}

fn peak_rss_kib() -> Option<u64> {
    #[cfg(target_os = "linux")]
    {
        let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
        // Linux reports ru_maxrss in KiB; other platforms use different units.
        if unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) } != 0 {
            return None;
        }
        u64::try_from(unsafe { usage.assume_init() }.ru_maxrss).ok()
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[tokio::test]
async fn same_root_rebound_device_and_foreign_owner_server_have_distinct_wire_ids() -> Result<()> {
    let original = make_request("same-notification");
    let source = original.source.clone();
    let (_delivery, first) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    first
        .enqueue(original.clone(), &anchor("root", "chat").await?)
        .await?;
    let mut ids = std::collections::BTreeSet::from([original.message_id()]);
    // Keep notification, session, generation, root and all source fields exact.
    // Only transport identity changes, including same-owner device reassignment.
    for (owner, server, device) in [
        (OWNER, SERVER, "rebound-device"),
        ("other-owner", SERVER, DEVICE),
        (OWNER, "ws://other-server.test/api/v1/agent/ws", DEVICE),
    ] {
        let identity = DeliveryIdentity::new(owner, server, device, "fixture-token")?;
        let proof = anchor_for(&identity, "root", "chat").await?;
        let delivery =
            DeliveryOutbox::open(Path::new(":memory:"), identity, DeliveryLimits::default())
                .await?;
        let outbox =
            ContinuationReplyOutbox::from_delivery(&delivery, ReplyLimits::default()).await?;
        assert!(
            outbox.enqueue(original.clone(), &proof).await.is_err(),
            "foreign namespace must be refused"
        );
        let mut req = original.clone();
        req.frame["message_id"] = json!(outbox.message_id(&source.notification_id));
        req.frame["content"] = json!("Independent producer result after binding change");
        assert_eq!(req.source, source);
        assert!(ids.insert(req.message_id()));
        assert!(req.message_id().len() <= 160);
        assert_eq!(
            outbox.enqueue(req.clone(), &proof).await?,
            ReplyStatus::Pending
        );
        assert_eq!(
            outbox.enqueue(req.clone(), &proof).await?,
            ReplyStatus::Pending
        );
        req.frame["content"] = json!("same source cannot overwrite its locally committed frame");
        assert!(outbox.enqueue(req, &proof).await.is_err());
        assert_eq!(outbox.pending_after(None, 32, 0).await?.len(), 1);
    }
    assert_eq!(ids.len(), 4);
    assert_eq!(
        first
            .inspect(&original.message_id())
            .await?
            .unwrap()
            .request,
        original
    );
    Ok(())
}

#[test]
fn reply_namespace_canonicalizes_server_and_excludes_credential() -> Result<()> {
    let canonical = DeliveryIdentity::new(OWNER, "ws://example.test/ws", DEVICE, "token-a")?;
    let mut equivalent = canonical.clone();
    equivalent.server_url = "ws://EXAMPLE.test:80/ws".into();
    let rotated = DeliveryIdentity::new(OWNER, "ws://example.test/ws", DEVICE, "token-b")?;
    let expected = ContinuationReplyOutbox::message_id_for(&canonical, "source")?;
    assert_eq!(
        expected,
        ContinuationReplyOutbox::message_id_for(&equivalent, "source")?
    );
    assert_eq!(
        expected,
        ContinuationReplyOutbox::message_id_for(&rotated, "source")?
    );
    let namespace =
        hash(&json!(["parent-reply-v1", "ws://example.test/ws", DEVICE, OWNER]).to_string());
    assert_eq!(
        expected,
        format!("parent-reply:{}:source", &namespace[..32])
    );
    assert!(ContinuationReplyOutbox::is_reply_id(&expected));
    Ok(())
}

#[tokio::test]
async fn scoped_wire_id_has_hard_160_byte_limit() -> Result<()> {
    let longest = "n".repeat(114);
    assert_eq!(
        ContinuationReplyOutbox::message_id_for(&identity(), &longest)?.len(),
        160
    );
    let too_long = "n".repeat(115);
    assert!(ContinuationReplyOutbox::message_id_for(&identity(), &too_long).is_err());
    let (_delivery, outbox) = open_outbox(Path::new(":memory:"), ReplyLimits::default()).await?;
    let mut req = make_request("short");
    req.source.notification_id = too_long.clone();
    req.source.input_id = format!("parent-continuation-{}", &hash(&too_long)[..40]);
    req.frame["message_id"] = json!(outbox.message_id(&too_long));
    assert!(
        outbox
            .enqueue(req, &anchor("root", "chat").await?)
            .await
            .is_err()
    );
    assert!(outbox.pending_after(None, 32, 0).await?.is_empty());
    Ok(())
}

#[tokio::test]
async fn legacy_unscoped_receipt_is_retained_but_never_sent_or_reidentified() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("legacy-development.sqlite");
    let proof = anchor("root", "chat").await?;
    let req = make_request("legacy-development");
    let legacy_id = format!("parent-reply:{}", req.source.notification_id);
    let mut legacy = req.clone();
    legacy.frame["message_id"] = json!(legacy_id);
    {
        let (_delivery, outbox) = open_outbox(&path, ReplyLimits::default()).await?;
        outbox.enqueue(req.clone(), &proof).await?;
    }
    // Synthetic pre-namespace development record; no production migration or
    // caller-supplied on-disk mutation path is exposed by the outbox itself.
    {
        let mut db = rusqlite::Connection::open(&path)?;
        let tx = db.transaction()?;
        let serialized = serde_json::to_string(&legacy)?;
        tx.execute(
            "UPDATE continuation_replies SET message_id=?1,request=?2,bytes=?3 WHERE message_id=?4",
            rusqlite::params![legacy_id, serialized, serialized.len(), req.message_id()],
        )?;
        tx.execute(
            "UPDATE continuation_reply_totals SET bytes=?1 WHERE id=1",
            [serialized.len()],
        )?;
        tx.commit()?;
    }
    let (_delivery, outbox) = open_outbox(&path, ReplyLimits::default()).await?;
    assert!(outbox.prepare_send(&legacy_id, 0).await?.is_none());
    let row = outbox.inspect(&legacy_id).await?.unwrap();
    assert_eq!(row.status, ReplyStatus::Suppressed);
    assert_eq!(row.attempts, 0);
    assert_eq!(row.request, legacy);
    assert!(
        row.diagnostic
            .unwrap()
            .contains("immutable receipt retained")
    );
    assert!(outbox.pending_after(None, 32, 0).await?.is_empty());
    assert!(
        outbox.enqueue(req, &proof).await.is_err(),
        "do not silently replace an old source identity with a new wire ID"
    );
    Ok(())
}
