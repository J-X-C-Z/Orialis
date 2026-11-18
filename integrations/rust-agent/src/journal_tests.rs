use super::*;
use rusqlite::StatementStatus;
use serde_json::json;

const IDENTITY: &str = "ws://127.0.0.1/api/v1/agent/ws|TE_ST_Journal";

fn payload(id: &str) -> Value {
    json!({"version":1,"type":"message.send","message_id":id,
        "conversation_id":"conversation","content":"synthetic journal test"})
}

fn final_frame(id: &str) -> Value {
    json!({"version":1,"type":"message.reply","message_id":format!("final_{id}"),
        "reply_to":id,"conversation_id":"conversation","content":"synthetic final"})
}

async fn state(journal: &Journal, id: &str) -> Result<String> {
    journal
        .call(|| {
            let id = id.to_owned();
            move |database: &mut Database| {
                Ok(database.connection.query_row(
                    "SELECT state FROM jobs WHERE id=?1",
                    [id],
                    |row| row.get(0),
                )?)
            }
        })
        .await
}

async fn failures(journal: &Journal, id: &str) -> Result<i64> {
    journal
        .call(|| {
            let id = id.to_owned();
            move |database: &mut Database| {
                Ok(database.connection.query_row(
                    "SELECT COALESCE((SELECT attempts FROM delivery_failures WHERE reply_id=?1),0)",
                    [id],
                    |row| row.get(0),
                )?)
            }
        })
        .await
}

#[tokio::test]
async fn identity_mismatch_does_not_recover_or_modify_existing_work() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("journal.db");
    let journal = Journal::open(&path, IDENTITY).await?;
    journal.claim("chat:running", &payload("running")).await?;
    journal.shutdown().await?;
    let mismatch = Journal::open(&path, "another server/device").await;
    assert!(
        mismatch
            .err()
            .unwrap()
            .to_string()
            .contains("another server/device")
    );
    let connection = crate::private_db::open_private(&path)?;
    assert_eq!(
        connection.query_row("SELECT state FROM jobs", [], |row| row.get::<_, String>(0))?,
        "running"
    );
    assert_eq!(
        connection.query_row("SELECT identity FROM agent_identity", [], |row| row
            .get::<_, String>(0))?,
        IDENTITY
    );
    drop(connection);
    let journal = Journal::open(&path, IDENTITY).await?;
    assert_eq!(state(&journal, "chat:running").await?, "uncertain");
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn duplicate_fingerprints_and_concurrent_claims_are_idempotent() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    let mut tasks = tokio::task::JoinSet::new();
    for _ in 0..32 {
        let journal = journal.clone();
        tasks.spawn(async move { journal.claim("chat:a", &payload("a")).await });
    }
    let mut new = 0;
    while let Some(result) = tasks.join_next().await {
        let (state, frame) = result??;
        assert!(matches!(state.as_str(), "new" | "running"));
        assert!(frame.is_none());
        new += usize::from(state == "new");
    }
    assert_eq!(new, 1);
    let mut changed = payload("a");
    changed["content"] = json!("different evidence");
    assert!(
        journal
            .claim("chat:a", &changed)
            .await
            .unwrap_err()
            .to_string()
            .contains("different evidence")
    );
    assert_eq!(state(&journal, "chat:a").await?, "running");
    journal.finish("chat:a", &final_frame("a")).await?;
    assert_eq!(
        journal.claim("chat:a", &payload("a")).await?,
        ("ready".into(), Some(final_frame("a")))
    );
    journal.ack("final_a").await?;
    assert_eq!(
        journal.claim("chat:a", &payload("a")).await?,
        ("delivered".into(), Some(final_frame("a")))
    );
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn queued_restart_is_retryable_but_started_work_is_uncertain() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("journal.db");
    let journal = Journal::open(&path, IDENTITY).await?;
    for id in ["queued", "started", "running"] {
        journal.claim(&format!("chat:{id}"), &payload(id)).await?;
    }
    journal.queued("queued", "queued").await?;
    journal.queued("started", "queued").await?;
    journal.queued("started", "running").await?;
    assert!(journal.queued("queued", "delivered").await.is_err());
    journal.shutdown().await?;
    let journal = Journal::open(&path, IDENTITY).await?;
    assert_eq!(state(&journal, "chat:queued").await?, "retryable");
    for id in ["started", "running"] {
        assert_eq!(
            journal.claim(&format!("chat:{id}"), &payload(id)).await?,
            ("uncertain".into(), None)
        );
    }
    assert_eq!(
        journal.claim("chat:queued", &payload("queued")).await?,
        ("new".into(), None)
    );
    journal.queued("queued", "queued").await?;
    journal.interrupted().await?;
    journal.interrupted().await?;
    assert_eq!(state(&journal, "chat:queued").await?, "retryable");
    assert_eq!(state(&journal, "chat:running").await?, "uncertain");
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn retryable_errors_are_not_finalized_and_require_identical_input() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    journal.claim("chat:a", &payload("a")).await?;
    journal
        .retryable(
            "chat:a",
            &json!({"type":"error","reply_to":"a","code":"RETRYABLE_TURN_FAILED"}),
        )
        .await?;
    journal.error_sent("a").await?;
    assert_eq!(state(&journal, "chat:a").await?, "retryable");
    assert!(journal.replay().await?.is_empty());
    assert!(journal.claim("chat:a", &payload("b")).await.is_err());
    assert_eq!(state(&journal, "chat:a").await?, "retryable");
    assert_eq!(
        journal.claim("chat:a", &payload("a")).await?,
        ("new".into(), None)
    );
    assert_eq!(
        journal.claim("chat:a", &payload("a")).await?,
        ("running".into(), None)
    );
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn replay_preserves_fifo_and_acks_only_final_replies() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    for id in ["z", "a", "m"] {
        journal.claim(&format!("chat:{id}"), &payload(id)).await?;
        journal
            .finish(&format!("chat:{id}"), &final_frame(id))
            .await?;
    }
    journal.reject("final_z").await?;
    // Insertion order, not lexicographic ID or state-index order.
    assert_eq!(
        journal.replay().await?,
        vec![final_frame("z"), final_frame("a"), final_frame("m")]
    );
    journal.ack("a").await?; // Input ACK must not finalize a reply.
    journal.ack("unknown").await?;
    assert_eq!(state(&journal, "chat:a").await?, "ready");
    journal.ack("final_a").await?;
    journal.ack("final_a").await?;
    assert!(!journal.prepare_reply_send("final_a").await?);
    assert_eq!(
        journal.replay().await?,
        vec![final_frame("z"), final_frame("m")]
    );
    journal.queued("a", "queued").await?;
    assert_eq!(state(&journal, "chat:a").await?, "delivered");
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn errors_and_memory_results_retain_original_delivery_semantics() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    let error = json!({"type":"error","reply_to":"a","code":"TURN_FAILED"});
    let memory = json!({"type":"memory.result","request_id":"a","content":"synthetic"});
    journal.claim("chat:a", &payload("a")).await?;
    journal
        .claim(
            "memory:a",
            &json!({"type":"memory.analyze","request_id":"a"}),
        )
        .await?;
    journal.finish("chat:a", &error).await?;
    journal.finish("memory:a", &memory).await?;
    assert_eq!(journal.replay().await?, vec![error.clone(), memory.clone()]);
    journal.error_sent("a").await?;
    journal.error_sent("a").await?;
    assert_eq!(journal.replay().await?, vec![memory]);
    journal.memory_sent("a").await?;
    journal.memory_sent("a").await?;
    assert!(journal.replay().await?.is_empty());
    assert_eq!(state(&journal, "chat:a").await?, "delivered");
    assert_eq!(state(&journal, "memory:a").await?, "delivered");
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn rejection_retries_are_bounded_and_persist_across_restarts() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("journal.db");
    let mut journal = Journal::open(&path, IDENTITY).await?;
    journal.claim("chat:a", &payload("a")).await?;
    journal.finish("chat:a", &final_frame("a")).await?;
    for attempt in 1..=3 {
        assert!(journal.prepare_reply_send("final_a").await?);
        let retry = journal.reject("final_a").await?;
        assert_eq!(retry, (attempt <= 2).then(|| final_frame("a")));
        assert_eq!(failures(&journal, "final_a").await?, attempt);
        assert!(journal.reject("final_a").await?.is_none());
        assert_eq!(failures(&journal, "final_a").await?, attempt);
        journal.shutdown().await?;
        journal = Journal::open(&path, IDENTITY).await?;
        assert_eq!(failures(&journal, "final_a").await?, attempt);
    }
    assert_eq!(state(&journal, "chat:a").await?, "rejected");
    assert!(!journal.prepare_reply_send("final_a").await?);
    journal.ack("final_a").await?; // An exhausted rejection remains terminal.
    assert_eq!(state(&journal, "chat:a").await?, "rejected");
    assert_eq!(
        journal.claim("chat:a", &payload("a")).await?,
        ("rejected".into(), Some(final_frame("a")))
    );
    assert!(journal.replay().await?.is_empty());
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn late_ack_during_retry_backoff_prevents_resend() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    journal.claim("chat:a", &payload("a")).await?;
    journal.finish("chat:a", &final_frame("a")).await?;
    assert_eq!(journal.reject("final_a").await?, Some(final_frame("a")));
    journal.ack("final_a").await?;
    assert!(!journal.prepare_reply_send("final_a").await?);
    assert!(journal.reject("final_a").await?.is_none());
    assert_eq!(failures(&journal, "final_a").await?, 1);
    assert_eq!(state(&journal, "chat:a").await?, "delivered");
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn rejection_counter_and_state_rollback_together() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    journal.claim("chat:a", &payload("a")).await?;
    journal.finish("chat:a", &final_frame("a")).await?;
    journal
        .call(|| {
            |database: &mut Database| {
                database.connection.execute_batch(
                    "CREATE TRIGGER reject_fault BEFORE UPDATE OF state ON jobs
             WHEN NEW.state='retry_wait' BEGIN SELECT RAISE(ABORT,'injected failure'); END;",
                )?;
                Ok(())
            }
        })
        .await?;
    assert!(journal.reject("final_a").await.is_err());
    assert_eq!(failures(&journal, "final_a").await?, 0);
    assert_eq!(state(&journal, "chat:a").await?, "ready");
    journal
        .call(|| {
            |database: &mut Database| {
                database
                    .connection
                    .execute_batch("DROP TRIGGER reject_fault")?;
                Ok(())
            }
        })
        .await?;
    assert_eq!(journal.reject("final_a").await?, Some(final_frame("a")));
    assert_eq!(failures(&journal, "final_a").await?, 1);
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn baseline_schema_upgrade_preserves_history_and_uses_indexes() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("legacy.db");
    {
        let mut connection = crate::private_db::open_private(&path)?;
        connection.execute_batch(SCHEMA)?;
        let transaction = connection.transaction()?;
        transaction.execute("INSERT INTO agent_identity VALUES(1,?1)", [IDENTITY])?;
        {
            let mut insert = transaction.prepare("INSERT INTO jobs VALUES(?1,?2,?3,?4)")?;
            for n in 0..10_000 {
                let id = format!("history_{n}");
                insert.execute(params![
                    format!("chat:{id}"),
                    crate::wire::digest(&serde_json::to_string(&payload(&id))?),
                    "delivered",
                    serde_json::to_string(&final_frame(&id))?
                ])?;
            }
            for (id, state) in [
                ("z", "retry_wait"),
                ("a", "ready"),
                ("queued", "queued"),
                ("running", "running"),
            ] {
                let frame = matches!(state, "retry_wait" | "ready")
                    .then(|| serde_json::to_string(&final_frame(id)))
                    .transpose()?;
                insert.execute(params![
                    format!("chat:{id}"),
                    crate::wire::digest(&serde_json::to_string(&payload(id))?),
                    state,
                    frame
                ])?;
            }
        }
        transaction.execute("INSERT INTO delivery_failures VALUES('final_z',1)", [])?;
        transaction.commit()?;
    }
    let journal = Journal::open(&path, IDENTITY).await?;
    assert_eq!(
        journal.replay().await?,
        vec![final_frame("z"), final_frame("a")]
    );
    assert_eq!(state(&journal, "chat:queued").await?, "retryable");
    assert_eq!(state(&journal, "chat:running").await?, "uncertain");
    assert_eq!(failures(&journal, "final_z").await?, 1);
    journal.call(|| |database: &mut Database| {
        let connection = &database.connection;
        assert_eq!(connection.query_row("PRAGMA synchronous", [], |row| row.get::<_, i64>(0))?, 2);
        assert_eq!(connection.query_row("PRAGMA journal_mode", [], |row| row.get::<_, String>(0))?, "wal");
        assert_eq!(connection.query_row("SELECT COUNT(*) FROM jobs", [], |row| row.get::<_, i64>(0))?, 10_004);
        assert_eq!(connection.query_row("SELECT COUNT(*) FROM jobs WHERE state='delivered'", [], |row| row.get::<_, i64>(0))?, 10_000);
        for sql in [ACK, REJECT_SELECT, REJECT_UPDATE, PREPARE_UPDATE, PREPARE_SELECT] {
            let mut statement = connection.prepare(&format!("EXPLAIN QUERY PLAN {sql}"))?;
            let bindings = vec!["final_a"; statement.parameter_count()];
            let plan = statement.query_map(rusqlite::params_from_iter(bindings), |row| row.get::<_, String>(3))?
                .collect::<rusqlite::Result<Vec<_>>>()?.join("; ");
            assert!(plan.contains("jobs_reply_id"), "reply lookup is not indexed: {sql}: {plan}");
            assert!(!plan.contains("SCAN jobs"), "unexpected history scan: {plan}");
        }
        let mut statement = connection.prepare(&format!("EXPLAIN QUERY PLAN {REPLAY}"))?;
        let plan = statement.query_map([], |row| row.get::<_, String>(3))?
            .collect::<rusqlite::Result<Vec<_>>>()?.join("; ");
        assert!(plan.contains("jobs_state"), "replay is not state-indexed: {plan}");
        let mut ack = connection.prepare(ACK)?;
        ack.execute(["final_a"])?;
        let instructions = ack.get_status(StatementStatus::VmStep);
        assert!(instructions < 200, "indexed ACK unexpectedly used {instructions} VM steps");
        eprintln!("Journal indexed ACK with 10,000 historical rows: {instructions} SQLite VM steps");
        Ok(())
    }).await?;
    journal.shutdown().await?;
    let journal = Journal::open(&path, IDENTITY).await?; // Upgrade is idempotent.
    assert_eq!(state(&journal, "chat:history_9999").await?, "delivered");
    assert_eq!(journal.replay().await?, vec![final_frame("z")]);
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test(flavor = "current_thread")]
async fn bounded_actor_backpressure_cancellation_and_shutdown_do_not_block_tokio() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("actor.db");
    let journal = Journal::open_with_capacity(&path, IDENTITY, 1).await?;
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let blocker = {
        let journal = journal.clone();
        tokio::spawn(async move {
            journal
                .call(|| {
                    move |_database: &mut Database| {
                        let _ = entered_tx.send(());
                        release_rx.recv_timeout(Duration::from_secs(5))?;
                        Ok(())
                    }
                })
                .await
        })
    };
    entered_rx.await?;
    let accepted = {
        let journal = journal.clone();
        tokio::spawn(async move { journal.claim("chat:accepted", &payload("accepted")).await })
    };
    tokio::time::timeout(Duration::from_secs(1), async {
        while journal.commands.capacity() != 0 {
            tokio::task::yield_now().await;
        }
    })
    .await?;
    let mut waiting = {
        let journal = journal.clone();
        tokio::spawn(async move {
            journal
                .claim("chat:unadmitted", &payload("unadmitted"))
                .await
        })
    };
    // This timer can fire on the sole Tokio thread while SQLite's actor is blocked.
    assert!(
        tokio::time::timeout(Duration::from_millis(20), &mut waiting)
            .await
            .is_err()
    );
    waiting.abort();
    assert!(waiting.await.unwrap_err().is_cancelled());
    // An admitted mutation must finish even when its caller is cancelled.
    accepted.abort();
    assert!(accepted.await.unwrap_err().is_cancelled());
    let shutdown = {
        let journal = journal.clone();
        tokio::spawn(async move { journal.shutdown().await })
    };
    release_tx.send(())?;
    blocker.await??;
    shutdown.await??;
    assert!(
        journal
            .claim("chat:closed", &payload("closed"))
            .await
            .is_err()
    );
    journal.shutdown().await?;
    let connection = crate::private_db::open_private(&path)?;
    assert_eq!(
        connection.query_row(
            "SELECT COUNT(*) FROM jobs WHERE id='chat:accepted'",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        1
    );
    assert_eq!(
        connection.query_row(
            "SELECT COUNT(*) FROM chat_input_provenance p JOIN jobs j ON j.id=p.job_id
             WHERE p.job_id='chat:accepted' AND p.payload_fingerprint=j.fingerprint",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        1,
        "an admitted cancelled producer commits input and provenance together"
    );
    assert_eq!(
        connection.query_row(
            "SELECT COUNT(*) FROM jobs WHERE id IN ('chat:unadmitted','chat:closed')",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        0
    );
    assert_eq!(
        connection.query_row(
            "SELECT COUNT(*) FROM chat_input_provenance WHERE job_id IN ('chat:unadmitted','chat:closed')",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        0
    );
    Ok(())
}

#[tokio::test]
async fn dropping_all_handles_closes_actor_and_zero_capacity_is_rejected() -> Result<()> {
    assert!(
        Journal::open_with_capacity(Path::new(":memory:"), IDENTITY, 0)
            .await
            .is_err()
    );
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    let mut stopped = journal.stopped.clone();
    let clone = journal.clone();
    drop(journal);
    assert!(!*stopped.borrow());
    clone.claim("chat:a", &payload("a")).await?;
    drop(clone);
    tokio::time::timeout(Duration::from_secs(2), stopped.wait_for(|stopped| *stopped)).await??;
    Ok(())
}

#[cfg(unix)]
#[tokio::test]
async fn actor_keeps_private_database_checks_and_permissions() -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("private.db");
    let journal = Journal::open(&path, IDENTITY).await?;
    journal.claim("chat:a", &payload("a")).await?;
    for suffix in ["", "-wal", "-shm"] {
        let metadata = std::fs::metadata(dir.path().join(format!("private.db{suffix}")))?;
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    }
    journal.shutdown().await?;
    let unsafe_path = dir.path().join("unsafe.db");
    std::fs::write(&unsafe_path, "unchanged")?;
    std::fs::set_permissions(&unsafe_path, std::fs::Permissions::from_mode(0o644))?;
    assert!(Journal::open(&unsafe_path, IDENTITY).await.is_err());
    assert_eq!(std::fs::read_to_string(&unsafe_path)?, "unchanged");
    assert_eq!(
        std::fs::metadata(&unsafe_path)?.permissions().mode() & 0o777,
        0o644
    );
    Ok(())
}

#[tokio::test]
async fn inspect_is_readonly_including_retryable_and_retry_wait_jobs() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    assert_eq!(journal.inspect("chat:missing").await?, None);
    journal.claim("chat:a", &payload("a")).await?;
    let error = json!({"type":"error","reply_to":"a","code":"RETRYABLE_TURN_FAILED"});
    journal.retryable("chat:a", &error).await?;
    assert_eq!(
        journal.inspect("chat:a").await?,
        Some(JournalEntry {
            state: "retryable".into(),
            frame: Some(error),
            rejection_attempts: 0,
        })
    );
    assert_eq!(state(&journal, "chat:a").await?, "retryable");
    journal.claim("chat:a", &payload("a")).await?;
    journal.finish("chat:a", &final_frame("a")).await?;
    journal.reject("final_a").await?;
    assert_eq!(
        journal.inspect("chat:a").await?,
        Some(JournalEntry {
            state: "retry_wait".into(),
            frame: Some(final_frame("a")),
            rejection_attempts: 1,
        })
    );
    assert_eq!(state(&journal, "chat:a").await?, "retry_wait");
    journal.shutdown().await?;
    Ok(())
}

#[tokio::test]
async fn malformed_legacy_frame_fails_upgrade_without_partial_changes() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let path = dir.path().join("malformed.db");
    {
        let connection = crate::private_db::open_private(&path)?;
        connection.execute_batch(SCHEMA)?;
        connection.execute("INSERT INTO agent_identity VALUES(1,?1)", [IDENTITY])?;
        connection.execute(
            "INSERT INTO jobs VALUES('chat:a','fingerprint','running','malformed JSON')",
            [],
        )?;
    }
    assert!(Journal::open(&path, IDENTITY).await.is_err());
    let connection = crate::private_db::open_private(&path)?;
    assert_eq!(
        connection.query_row("SELECT state FROM jobs", [], |row| row.get::<_, String>(0))?,
        "running"
    );
    assert_eq!(
        connection.query_row("SELECT frame FROM jobs", [], |row| row.get::<_, String>(0))?,
        "malformed JSON"
    );
    assert_eq!(
        connection.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name IN ('jobs_reply_id','jobs_state')",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        0
    );
    Ok(())
}

#[tokio::test]
async fn paged_replay_preserves_order_without_acknowledged_or_rejected_rows() -> Result<()> {
    let journal = Journal::open(Path::new(":memory:"), IDENTITY).await?;
    let mut expected = Vec::new();
    for n in 0..103 {
        let id = format!("page-{n}");
        let key = format!("chat:{id}");
        journal.claim(&key, &payload(&id)).await?;
        journal.finish(&key, &final_frame(&id)).await?;
        if n % 4 == 0 {
            journal.ack(&format!("final_{id}")).await?;
        } else if n % 4 == 1 {
            for _ in 0..3 {
                let _ = journal.reject(&format!("final_{id}")).await?;
                let _ = journal.prepare_reply_send(&format!("final_{id}")).await?;
            }
        } else {
            expected.push(final_frame(&id));
        }
    }
    let mut cursor = 0;
    let mut replay = Vec::new();
    loop {
        let page = journal.replay_page(cursor, 7).await?;
        assert!(page.len() <= 7);
        if page.is_empty() {
            break;
        }
        for (id, frame) in page {
            assert!(id > cursor);
            cursor = id;
            replay.push(frame);
        }
    }
    assert_eq!(replay, expected);
    assert_eq!(replay, journal.replay().await?);
    assert!(journal.replay_page(-1, 1).await.is_err());
    assert!(journal.replay_page(0, 0).await.is_err());
    assert!(journal.replay_page(0, 257).await.is_err());
    journal.shutdown().await?;
    Ok(())
}
