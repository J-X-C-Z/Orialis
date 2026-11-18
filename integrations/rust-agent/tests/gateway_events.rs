//! In-process event actor/lifecycle tests. Wire interoperability is checked by
//! gateway_events_contract.py against original Python + real Orialis Server.
use hermes_rust_core::gateway_events::{AckOutcome, CAPABILITIES, EventLimits, GatewayEvents};
use hermes_rust_core::tool_runtime;
use serde_json::{Value, json};
use tool_runtime::{TurnContext, TurnEvent};

fn context(name: &str) -> TurnContext {
    TurnContext {
        conversation_id: name.into(),
        input_id: format!("input-{name}"),
        session_id: format!("history-{name}"),
    }
}
fn caps() -> Value {
    json!({"version":1,"type":"hello_ack","capabilities":CAPABILITIES})
}
fn ack(frame: &Value, status: &str) -> Value {
    json!({"version":1,"type":"agent.ack","event_id":frame["event_id"],"seq":frame["seq"],"status":status})
}
async fn service() -> GatewayEvents {
    let service = GatewayEvents::open(std::path::Path::new(":memory:"), "test-device")
        .await
        .unwrap();
    service.negotiate(&caps()).await.unwrap();
    service
}

#[tokio::test]
async fn lifecycle_complete_waits_for_actual_stored_reply_and_matches_its_id() {
    let service = service().await;
    let mut run = service.begin_run(&context("chat")).await.unwrap();
    run.observe(TurnEvent::Started).await.unwrap(); // idempotent
    run.observe(TurnEvent::Delta("你".into())).await.unwrap();
    run.observe(TurnEvent::Delta("好".into())).await.unwrap();
    run.observe(TurnEvent::ToolStarted {
        id: "call1".into(),
        name: "memory".into(),
    })
    .await
    .unwrap();
    run.observe(TurnEvent::ToolCompleted {
        id: "call1".into(),
        name: "memory".into(),
        failed: false,
    })
    .await
    .unwrap();
    run.observe(TurnEvent::ToolStarted {
        id: "call2".into(),
        name: "news.list".into(),
    })
    .await
    .unwrap();
    run.observe(TurnEvent::ToolCompleted {
        id: "call2".into(),
        name: "news.list".into(),
        failed: true,
    })
    .await
    .unwrap();
    run.observe(TurnEvent::Completed).await.unwrap();
    run.defer_completion("actual-final-message-1", "你好 corrected final")
        .await
        .unwrap();
    let pending = service.pending_after(0, 128).await.unwrap();
    assert_eq!(
        pending
            .iter()
            .filter(|v| v["type"] == "agent.start")
            .count(),
        1
    );
    assert!(!pending.iter().any(|v| v["type"] == "agent.complete"));
    service
        .confirm_message("wrong-final-message")
        .await
        .unwrap();
    assert_eq!(service.pending_after(0, 128).await.unwrap(), pending);
    service
        .confirm_message("actual-final-message-1")
        .await
        .unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    let end = frames.last().unwrap();
    assert_eq!(end["type"], "agent.complete");
    assert_eq!(end["message_id"], "actual-final-message-1");
    assert_eq!(end["content"], "你好 corrected final");
    for (i, frame) in frames.iter().enumerate() {
        assert_eq!(frame["seq"], i + 1);
        assert_eq!(frame["run_id"], run.run_id());
        assert_eq!(frame["session_id"], frames[0]["session_id"]);
    }
    let ids: std::collections::HashSet<_> = frames
        .iter()
        .map(|f| f["event_id"].as_str().unwrap())
        .collect();
    assert_eq!(ids.len(), frames.len());
    assert!(
        frames
            .iter()
            .any(|f| f["type"] == "tool.failed" && f["code"] == "TOOL_FAILED")
    );
    service
        .confirm_message("actual-final-message-1")
        .await
        .unwrap();
    assert_eq!(service.pending_after(0, 128).await.unwrap(), frames);
    for frame in frames {
        assert_eq!(
            service.acknowledge(&ack(&frame, "received")).await.unwrap(),
            AckOutcome::Accepted
        );
    }
    assert_eq!(service.snapshot().await.unwrap().pending_events, 0);
    assert!(run.append("too late").await.is_err());
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn cumulative_snapshots_only_emit_utf8_suffix_and_rewrite_corrects_at_completion() {
    let service = service().await;
    let mut run = service.begin_run(&context("snap")).await.unwrap();
    for text in [
        "",
        "你",
        "你好",
        "你好",
        "你好 world",
        "rewrite",
        "rewritten final",
    ] {
        run.snapshot(text).await.unwrap();
    }
    assert_eq!(run.content(), "rewritten final");
    run.defer_completion("final-snapshot", "rewritten final")
        .await
        .unwrap();
    service.confirm_message("final-snapshot").await.unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    let deltas: Vec<_> = frames
        .iter()
        .filter(|f| f["type"] == "agent.delta")
        .map(|f| f["delta"].as_str().unwrap())
        .collect();
    assert_eq!(deltas, vec!["你", "好", " world"]);
    assert_eq!(frames.last().unwrap()["content"], "rewritten final");
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn incremental_repeated_tokens_are_not_wrongly_deduplicated() {
    let service = service().await;
    let mut run = service.begin_run(&context("tokens")).await.unwrap();
    for token in ["ha", "ha", "ha"] {
        run.append(token).await.unwrap();
    }
    assert_eq!(run.content(), "hahaha");
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(
        frames.iter().filter(|f| f["type"] == "agent.delta").count(),
        3
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn parallel_runs_have_global_seq_one_epoch_and_scoped_tool_call_ids() {
    let service = service().await;
    let mut tasks = tokio::task::JoinSet::new();
    for i in 0..12 {
        let service = service.clone();
        tasks.spawn(async move {
            let mut run = service
                .begin_run(&context(&format!("chat-{i}")))
                .await
                .unwrap();
            run.observe(TurnEvent::ToolStarted {
                id: "reused-provider-id".into(),
                name: "test".into(),
            })
            .await
            .unwrap();
            run.append(&format!("answer-{i}")).await.unwrap();
            run.observe(TurnEvent::ToolCompleted {
                id: "reused-provider-id".into(),
                name: "test".into(),
                failed: false,
            })
            .await
            .unwrap();
            run.defer_completion(&format!("final-{i}"), &format!("answer-{i}"))
                .await
                .unwrap();
            service
                .confirm_message(&format!("final-{i}"))
                .await
                .unwrap();
        });
    }
    while let Some(result) = tasks.join_next().await {
        result.unwrap();
    }
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.len(), 84);
    let mut calls = std::collections::HashSet::new();
    let mut sessions = std::collections::HashSet::new();
    for (i, frame) in frames.iter().enumerate() {
        assert_eq!(frame["seq"], i + 1);
        sessions.insert(frame["session_id"].as_str().unwrap());
        if frame["type"] == "tool.started" {
            calls.insert(frame["tool_call_id"].as_str().unwrap());
        }
        if frame["type"] == "agent.complete" {
            let suffix = frame["conversation_id"]
                .as_str()
                .unwrap()
                .strip_prefix("chat-")
                .unwrap();
            assert_eq!(frame["content"], format!("answer-{suffix}"));
        }
    }
    assert_eq!(calls.len(), 12);
    assert_eq!(sessions.len(), 1);
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn receipt_must_match_id_and_seq_out_of_order_ack_keeps_replayable_prefix() {
    let service = service().await;
    let mut run = service.begin_run(&context("gap")).await.unwrap();
    run.append("x").await.unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.len(), 3);
    let mut wrong = ack(&frames[0], "received");
    wrong["seq"] = json!(2);
    assert_eq!(
        service.acknowledge(&wrong).await.unwrap(),
        AckOutcome::Ignored
    );
    service
        .acknowledge(&ack(&frames[2], "received"))
        .await
        .unwrap();
    assert_eq!(service.snapshot().await.unwrap().acknowledged_seq, 0);
    let mut gap = ack(&frames[2], "gap");
    gap["expected_seq"] = json!(1);
    assert_eq!(
        service.acknowledge(&gap).await.unwrap(),
        AckOutcome::ReplayFrom(1)
    );
    assert_eq!(service.pending_after(0, 128).await.unwrap(), frames);
    service
        .acknowledge(&ack(&frames[0], "duplicate"))
        .await
        .unwrap();
    assert_eq!(service.snapshot().await.unwrap().acknowledged_seq, 1);
    assert!(service.acknowledge(&gap).await.is_err()); // missing pruned prefix cannot be invented
    assert_eq!(
        service
            .acknowledge(&ack(&frames[0], "received"))
            .await
            .unwrap(),
        AckOutcome::Ignored
    );
    assert!(
        service
            .acknowledge(&ack(&frames[1], "unknown"))
            .await
            .is_err()
    );
    assert_eq!(service.pending_after(0, 128).await.unwrap().len(), 2);
    let mut malformed = ack(&frames[1], "gap");
    malformed["expected_seq"] = json!(false);
    assert!(service.acknowledge(&malformed).await.is_err());
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn reconnect_replays_identical_bytes_and_process_restart_preserves_pending_completion() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("events.sqlite");
    let service = GatewayEvents::open(&path, "stable-device").await.unwrap();
    service.negotiate(&caps()).await.unwrap();
    let mut run = service.begin_run(&context("persist")).await.unwrap();
    run.append("saved").await.unwrap();
    run.defer_completion("saved-final", "saved").await.unwrap();
    let old = service.pending_after(0, 128).await.unwrap();
    let state = service.snapshot().await.unwrap();
    service.shutdown().await.unwrap();
    let reopened = GatewayEvents::open(&path, "stable-device").await.unwrap();
    assert!(reopened.pending_after(0, 128).await.is_err());
    reopened.negotiate(&json!({"version":1,"type":"capabilities.ack","capabilities":CAPABILITIES,"resume_from":0,"next_seq":9999})).await.unwrap();
    assert_eq!(reopened.pending_after(0, 128).await.unwrap(), old);
    let after = reopened.snapshot().await.unwrap();
    assert_eq!(after.session_id, state.session_id);
    assert_eq!(after.last_seq, state.last_seq);
    assert_eq!(after.pending_completions, 1);
    reopened.confirm_message("saved-final").await.unwrap();
    let frames = reopened.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.last().unwrap()["seq"], state.last_seq + 1);
    assert_eq!(frames.last().unwrap()["message_id"], "saved-final");
    for frame in &frames {
        reopened.acknowledge(&ack(frame, "received")).await.unwrap();
    }
    let mut next = reopened.begin_run(&context("next")).await.unwrap();
    next.fail("TEST_FAILURE", "safe failure").await.unwrap();
    let after = reopened.pending_after(0, 128).await.unwrap();
    assert_eq!(after[0]["seq"], state.last_seq + 2);
    reopened.shutdown().await.unwrap();
    assert!(GatewayEvents::open(&path, "another-device").await.is_err());
}

#[tokio::test]
async fn capacity_rejection_allocates_no_sequence_and_ack_releases_space() {
    let service = GatewayEvents::open_with_limits(
        std::path::Path::new(":memory:"),
        "bounded",
        EventLimits {
            max_events: 3,
            max_bytes: 4096,
            actor_capacity: 1,
        },
    )
    .await
    .unwrap();
    service.negotiate(&caps()).await.unwrap();
    let mut run = service.begin_run(&context("bounded")).await.unwrap();
    run.append("a").await.unwrap();
    assert!(run.append("b").await.is_err());
    assert_eq!(run.content(), "a");
    assert_eq!(service.snapshot().await.unwrap().last_seq, 3);
    let frames = service.pending_after(0, 128).await.unwrap();
    service
        .acknowledge(&ack(&frames[0], "received"))
        .await
        .unwrap();
    run.append("b").await.unwrap();
    assert_eq!(service.snapshot().await.unwrap().last_seq, 4);
    assert_eq!(service.pending_after(3, 1).await.unwrap()[0]["delta"], "b");
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn deferred_completion_reserves_capacity_and_moves_atomically_without_overflow() {
    let service = GatewayEvents::open_with_limits(
        std::path::Path::new(":memory:"),
        "bounded",
        EventLimits {
            max_events: 4,
            max_bytes: 4096,
            actor_capacity: 1,
        },
    )
    .await
    .unwrap();
    service.negotiate(&caps()).await.unwrap();
    let mut run = service.begin_run(&context("bounded")).await.unwrap();
    run.defer_completion("final", "answer").await.unwrap();
    let staged = service.snapshot().await.unwrap();
    assert_eq!(staged.pending_completions, 1);
    assert_eq!(staged.pending_events, 3);
    assert!(staged.retained_bytes <= 4096);
    service.confirm_message("final").await.unwrap();
    let published = service.snapshot().await.unwrap();
    assert_eq!(published.pending_events, 4);
    assert_eq!(published.pending_completions, 0);
    assert!(published.retained_bytes <= staged.retained_bytes);
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn legacy_and_partial_capabilities_allocate_only_supported_events() {
    let service = GatewayEvents::open(std::path::Path::new(":memory:"), "legacy")
        .await
        .unwrap();
    service
        .negotiate(&json!({"version":1,"type":"hello_ack"}))
        .await
        .unwrap();
    let mut run = service.begin_run(&context("legacy")).await.unwrap();
    run.append("final-only").await.unwrap();
    run.defer_completion("legacy-final", "final-only")
        .await
        .unwrap();
    service.confirm_message("legacy-final").await.unwrap();
    assert_eq!(service.snapshot().await.unwrap().last_seq, 0);
    service.negotiate(&json!({"version":1,"type":"hello_ack","capabilities":["streaming","approval.request","clarify.request","agent.typing"]})).await.unwrap();
    let mut run = service.begin_run(&context("typing")).await.unwrap();
    run.append("not streamed").await.unwrap();
    run.observe(TurnEvent::Completed).await.unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.len(), 2);
    assert!(frames.iter().all(|f| f["type"] == "agent.typing"));
    assert_eq!(frames[0]["seq"], 1);
    service.commit_inbound(1).await.unwrap();
    service.commit_inbound(1).await.unwrap();
    assert!(service.commit_inbound(3).await.is_err());
    let hello = service
        .capabilities_hello(&["messages".into()])
        .await
        .unwrap();
    assert_eq!(hello["resume_from"], 1);
    assert!(
        hello["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("messages"))
    );
    assert!(
        !hello["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("approval.request"))
    );
    assert_eq!(service.snapshot().await.unwrap().inbound_seq, 1);
    service
        .negotiate(&json!({"version":1,"type":"hello_ack"}))
        .await
        .unwrap();
    assert!(service.pending_after(0, 128).await.is_err());
    service.shutdown().await.unwrap();
}

/// Interoperability fixture generated from this implementation, not handwritten
/// JSON templates. The Python runner sets EVENT_CONTRACT_FIXTURE then runs this.
#[tokio::test]
async fn export_contract_fixture() {
    let Ok(path) = std::env::var("EVENT_CONTRACT_FIXTURE") else {
        return;
    };
    let service = service().await;
    let mut run = service
        .begin_run(&context("contract-conversation"))
        .await
        .unwrap();
    run.snapshot("Hello").await.unwrap();
    run.snapshot("Hello world").await.unwrap();
    run.snapshot("Hello world").await.unwrap();
    run.observe(TurnEvent::ToolStarted {
        id: "tool-1".into(),
        name: "test".into(),
    })
    .await
    .unwrap();
    run.observe(TurnEvent::ToolCompleted {
        id: "tool-1".into(),
        name: "test".into(),
        failed: false,
    })
    .await
    .unwrap();
    run.observe(TurnEvent::ToolStarted {
        id: "tool-2".into(),
        name: "test".into(),
    })
    .await
    .unwrap();
    run.observe(TurnEvent::ToolCompleted {
        id: "tool-2".into(),
        name: "test".into(),
        failed: true,
    })
    .await
    .unwrap();
    run.defer_completion("contract-final-message", "Hello world")
        .await
        .unwrap();
    service
        .confirm_message("contract-final-message")
        .await
        .unwrap();
    let mut other = service
        .begin_run(&context("other-conversation"))
        .await
        .unwrap();
    other
        .fail("PROVIDER_FAILED", "Provider failed")
        .await
        .unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    std::fs::write(path, serde_json::to_vec_pretty(&frames).unwrap()).unwrap();
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn restart_closes_abandoned_run_without_retrying_provider_or_tools() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("interrupted.sqlite");
    let service = GatewayEvents::open(&path, "same-device").await.unwrap();
    service.negotiate(&caps()).await.unwrap();
    let mut run = service.begin_run(&context("interrupted")).await.unwrap();
    run.append("partial").await.unwrap();
    let original = service.pending_after(0, 128).await.unwrap();
    let id = run.run_id().to_owned();
    // No completion, simulating process death after committed start/delta.
    service.shutdown().await.unwrap();
    drop(run);
    drop(service);
    let service = GatewayEvents::open(&path, "same-device").await.unwrap();
    service.negotiate(&caps()).await.unwrap();
    let recovered = service.pending_after(0, 128).await.unwrap();
    assert_eq!(&recovered[..original.len()], original);
    assert_eq!(recovered.len(), original.len() + 2);
    assert_eq!(recovered.last().unwrap()["type"], "agent.error");
    assert_eq!(recovered.last().unwrap()["code"], "PROCESS_INTERRUPTED");
    assert_eq!(recovered.last().unwrap()["run_id"], id);
    assert_eq!(
        recovered.last().unwrap()["session_id"],
        original[0]["session_id"]
    );
    service.negotiate(&caps()).await.unwrap();
    assert_eq!(service.pending_after(0, 128).await.unwrap(), recovered);
    tokio::time::timeout(std::time::Duration::from_secs(1), service.notified())
        .await
        .unwrap();
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn exact_support_query_and_heartbeat_follow_negotiation_and_lifecycle() {
    let service = GatewayEvents::open(std::path::Path::new(":memory:"), "heartbeat")
        .await
        .unwrap();
    assert!(!service.supports("agent.delta").await.unwrap());
    service.negotiate(&caps()).await.unwrap();
    assert!(service.supports("agent.delta").await.unwrap());
    assert!(!service.supports("approval.request").await.unwrap());
    let mut run = service.begin_run(&context("heartbeat")).await.unwrap();
    run.heartbeat().await.unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[2]["type"], "agent.typing");
    assert_eq!(frames[2]["typing"], true);
    run.observe(TurnEvent::Completed).await.unwrap();
    let before = service.snapshot().await.unwrap().last_seq;
    run.heartbeat().await.unwrap();
    assert_eq!(service.snapshot().await.unwrap().last_seq, before);
    run.defer_completion("heartbeat-final", "answer")
        .await
        .unwrap();
    run.heartbeat().await.unwrap();
    assert_eq!(service.snapshot().await.unwrap().last_seq, before);
    service
        .negotiate(&json!({"version":1,"type":"hello_ack"}))
        .await
        .unwrap();
    assert!(!service.supports("agent.delta").await.unwrap());
    let mut legacy = service
        .begin_run(&context("legacy-heartbeat"))
        .await
        .unwrap();
    legacy.heartbeat().await.unwrap();
    assert_eq!(service.snapshot().await.unwrap().last_seq, before);
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn completion_candidates_reconcile_journal_ack_crash_window() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("ack-window.sqlite");
    let service = GatewayEvents::open(&path, "same-device").await.unwrap();
    service.negotiate(&caps()).await.unwrap();
    let mut run = service.begin_run(&context("ack-window")).await.unwrap();
    run.defer_completion("stored-actual-id", "stored answer")
        .await
        .unwrap();
    assert_eq!(
        service.completion_candidates().await.unwrap(),
        vec![("input-ack-window".into(), "stored-actual-id".into())]
    );
    // Host journal durably committed delivered, then process died before event
    // confirm_message. On restart inspect delivered + exact stored message ID.
    service.shutdown().await.unwrap();
    let service = GatewayEvents::open(&path, "same-device").await.unwrap();
    service.negotiate(&caps()).await.unwrap();
    let candidates = service.completion_candidates().await.unwrap();
    assert_eq!(candidates.len(), 1);
    assert_eq!(
        candidates[0],
        ("input-ack-window".into(), "stored-actual-id".into())
    );
    service.confirm_message(&candidates[0].1).await.unwrap();
    assert!(service.completion_candidates().await.unwrap().is_empty());
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.last().unwrap()["message_id"], "stored-actual-id");
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn optional_features_require_host_registration_and_peer_negotiation() {
    let service = service().await;
    let request = json!({"type":"approval.request","conversation_id":"feature-chat","request_id":"approval-1","action":"Test action","details":{"scope":"synthetic"},"timeout_ms":1000});
    assert!(service.enqueue_feature(request.clone()).await.is_err());
    assert!(
        service
            .enable_features(&["unknown.feature".into()])
            .await
            .is_err()
    );
    service
        .enable_features(&["approval.request".into()])
        .await
        .unwrap();
    assert!(service.enqueue_feature(request.clone()).await.is_err());
    assert!(!service.supports("approval.request").await.unwrap());
    service.negotiate(&json!({"version":1,"type":"hello_ack","capabilities":["approval.request","agent.start","agent.typing"]})).await.unwrap();
    assert!(service.supports("approval.request").await.unwrap());
    for reserved in ["version", "event_id", "seq", "session_id", "sequence"] {
        let mut invalid = request.clone();
        invalid[reserved] = json!(1);
        assert!(service.enqueue_feature(invalid).await.is_err());
    }
    let mut invalid = request.clone();
    invalid["timeout_ms"] = json!(0);
    assert!(service.enqueue_feature(invalid).await.is_err());
    assert_eq!(service.snapshot().await.unwrap().last_seq, 0);
    let _run = service.begin_run(&context("feature-chat")).await.unwrap();
    service.enqueue_feature(request).await.unwrap();
    let frames = service.pending_after(0, 128).await.unwrap();
    assert_eq!(frames.len(), 3);
    assert_eq!(frames[2]["seq"], 3);
    assert_eq!(frames[2]["type"], "approval.request");
    assert_eq!(frames[2]["session_id"], frames[0]["session_id"]);
    let hello = service.capabilities_hello(&[]).await.unwrap();
    assert!(
        hello["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("approval.request"))
    );
    assert!(
        !hello["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("clarify.request"))
    );
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn optional_feature_validation_matches_release_resolve_fields() {
    use hermes_rust_core::gateway_events::FEATURE_CAPABILITIES;
    let service = service().await;
    let features: Vec<String> = FEATURE_CAPABILITIES.iter().map(|s| (*s).into()).collect();
    service.enable_features(&features).await.unwrap();
    service
        .negotiate(&json!({"version":1,"type":"hello_ack","capabilities":features}))
        .await
        .unwrap();
    let valid = [
        json!({"type":"clarify.request","conversation_id":"feature","request_id":"q","question":"Choose?","choices":["A","B"],"multi_select":false}),
        json!({"type":"clarify.resolve","conversation_id":"feature","request_id":"q","answer":"A"}),
        json!({"type":"clarify.cancel","conversation_id":"feature","request_id":"q","reason":"cancelled"}),
        json!({"type":"approval.request","conversation_id":"feature","request_id":"a","action":"Test","timeout_ms":1000}),
        json!({"type":"approval.resolve","conversation_id":"feature","request_id":"a","decision":"deny"}),
    ];
    for frame in valid {
        service.enqueue_feature(frame).await.unwrap();
    }
    assert!(service.enqueue_feature(json!({"type":"clarify.resolve","conversation_id":"feature","request_id":"q","response":"old Python alias"})).await.is_err());
    assert!(service.enqueue_feature(json!({"type":"approval.resolve","conversation_id":"feature","request_id":"a","decision":"approve"})).await.is_err());
    assert_eq!(service.snapshot().await.unwrap().last_seq, 5);
    service.shutdown().await.unwrap();
}

#[tokio::test]
async fn artifact_source_handoff_is_atomic_restart_durable_and_never_republished_after_ack() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("events.sqlite");
    let caps = vec![
        "artifact.started".to_string(),
        "artifact.progress".to_string(),
        "artifact.completed".to_string(),
        "artifact.failed".to_string(),
    ];
    let e = GatewayEvents::open(&path, "device").await.unwrap();
    e.enable_features(&caps).await.unwrap();
    e.negotiate(&json!({"type":"hello_ack","version":1,"capabilities":caps}))
        .await
        .unwrap();
    let frames = [
        json!({"type":"artifact.started","conversation_id":"c","artifact":{"id":"f","kind":"document","size":1,"name":"a"}}),
        json!({"type":"artifact.progress","conversation_id":"c","artifact_id":"f","progress":{"phase":"uploading","bytes":1}}),
        json!({"type":"artifact.completed","conversation_id":"c","artifact":{"id":"f","kind":"document","mime_type":"text/plain","uri":"/api/attachment/f"}}),
        json!({"type":"artifact.failed","conversation_id":"c","artifact_id":"f","code":"UNKNOWN","message":"Unknown outcome","metadata":{"outcomeUnknown":true}}),
    ];
    for (i, f) in frames.iter().enumerate() {
        e.enqueue_feature_once(&format!("db-epoch:event:{i}"), f.clone())
            .await
            .unwrap();
    }
    let before = e.pending_after(0, 128).await.unwrap();
    assert_eq!(before.len(), 4);
    e.enqueue_feature_once("db-epoch:event:0", frames[0].clone())
        .await
        .unwrap();
    let mut altered = frames[0].clone();
    altered["artifact"]["name"] = json!("b");
    assert!(
        e.enqueue_feature_once("db-epoch:event:0", altered)
            .await
            .is_err()
    );
    for f in &before {
        e.acknowledge(&ack(f, "received")).await.unwrap();
    }
    assert!(e.pending_after(0, 128).await.unwrap().is_empty());
    e.shutdown().await.unwrap();
    let e = GatewayEvents::open(&path, "device").await.unwrap();
    e.enable_features(&caps).await.unwrap();
    e.negotiate(&json!({"type":"hello_ack","version":1,"capabilities":caps}))
        .await
        .unwrap();
    e.enqueue_feature_once("db-epoch:event:0", frames[0].clone())
        .await
        .unwrap();
    assert_eq!(e.snapshot().await.unwrap().last_seq, 4);
    assert!(e.pending_after(0, 128).await.unwrap().is_empty());
    let mut bad = frames[0].clone();
    bad["artifact"]["mime_type"] = json!("video/mp4");
    assert!(e.enqueue_feature(bad).await.is_err());
    let mut bad = frames[0].clone();
    bad["artifact"]["size"] = json!(-1);
    assert!(e.enqueue_feature(bad).await.is_err());
    e.shutdown().await.unwrap();
}

#[tokio::test]
async fn artifact_capacity_failure_does_not_consume_source_receipt_or_sequence() {
    let e = GatewayEvents::open_with_limits(
        std::path::Path::new(":memory:"),
        "d",
        EventLimits {
            max_events: 1,
            max_bytes: 4096,
            actor_capacity: 4,
        },
    )
    .await
    .unwrap();
    let caps = vec!["artifact.progress".into()];
    e.enable_features(&caps).await.unwrap();
    e.negotiate(&json!({"type":"hello_ack","version":1,"capabilities":caps}))
        .await
        .unwrap();
    let f =
        json!({"type":"artifact.progress","conversation_id":"c","artifact_id":"f","progress":50});
    e.enqueue_feature_once("first", f.clone()).await.unwrap();
    assert!(e.enqueue_feature_once("second", f.clone()).await.is_err());
    assert_eq!(e.snapshot().await.unwrap().last_seq, 1);
    let first = e.pending_after(0, 1).await.unwrap().remove(0);
    e.acknowledge(&ack(&first, "received")).await.unwrap();
    e.enqueue_feature_once("second", f).await.unwrap();
    assert_eq!(e.snapshot().await.unwrap().last_seq, 2);
    e.shutdown().await.unwrap();
}
