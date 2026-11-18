//! Scope/receipt tests use a labelled mock provider unless explicitly stated.
use anyhow::{Result, ensure};
use hermes_rust_core::{
    ChatRequest, Core, Provider, Store,
    session_commands::{self as commands, CommandRequest, NormalizedCommand, SessionSelector},
    session_context::CompressionPolicy,
    tool_runtime::TurnContext,
    wire,
};
use serde_json::{Value, json};
use std::path::Path;
fn core(path: &Path) -> Result<Core> {
    Core::new(
        Store::open(path)?,
        Provider::new(
            "http://127.0.0.1:1/no-model-call".into(),
            "mock-for-history-fixture".into(),
            None,
            true,
        )?,
    )
    .with_session_context("fixture-owner".into(), CompressionPolicy::default())
}
fn context(conversation: &str, id: &str) -> TurnContext {
    TurnContext {
        conversation_id: conversation.into(),
        input_id: id.into(),
        session_id: wire::digest(conversation),
    }
}
fn request(conv: &str, id: &str, text: &str) -> Result<CommandRequest> {
    commands::normalize(&json!({"version":1,"type":"message.send","conversation_id":conv,"message_id":id,"content":text}),&context(conv,id))?.ok_or_else(||anyhow::anyhow!("not a command"))
}
async fn chat(core: &Core, conv: &str, id: &str, text: &str) -> Result<()> {
    core.chat_with_context(
        ChatRequest {
            session_id: wire::digest(conv),
            message: text.into(),
        },
        context(conv, id),
        None,
    )
    .await?;
    Ok(())
}
#[test]
fn normalization_checks_anchors_and_actual_reply_kinds() -> Result<()> {
    assert_eq!(
        request("0", "i", "/session info 0")?.command(),
        &NormalizedCommand::Info {
            session: SessionSelector::Generation(0)
        }
    );
    assert_eq!(
        request("c", "i", "/reset")?.command(),
        &NormalizedCommand::HostReset
    );
    assert_eq!(
        request("c", "i", "/new")?.command(),
        &NormalizedCommand::HostReset
    );
    assert_eq!(
        request("c", "i", "/session history 2 --limit 3 --offset 4")?.command(),
        &NormalizedCommand::History {
            session: SessionSelector::Generation(2),
            limit: 3,
            offset: 4
        }
    );
    for text in [
        "/model other",
        "/tools all",
        "/sessions all",
        "/sessions resume",
        "/new named",
        "/session open",
    ] {
        assert!(matches!(
            request("c", "i", text)?.command(),
            NormalizedCommand::Unsupported { .. }
        ));
    }
    for text in [
        "/session history other",
        "/session history --limit 0",
        "/sessions --limit 51",
        "/sessions --offset 100001",
        "/session info 01",
    ] {
        assert!(request("c", "i", text).is_err(), "{text}");
    }
    let mut frame = json!({"version":1,"type":"command.request","conversation_id":"c","request_id":"i","command":"sessions","args":"--limit 2"});
    let req = commands::normalize(&frame, &context("c", "i"))?.unwrap();
    assert!(matches!(
        req.command(),
        NormalizedCommand::List { limit: 2, .. }
    ));
    frame["type"] = json!("slash.command");
    assert!(commands::normalize(&frame, &context("c", "i"))?.is_some());
    frame["conversation_id"] = json!("other");
    assert!(commands::normalize(&frame, &context("c", "i")).is_err());
    assert!(commands::normalize(&json!({"version":1,"type":"message.send","conversation_id":"c","message_id":"wrong","content":"/sessions"}),&context("c","i")).is_err());
    assert!(commands::normalize(&json!({"version":1,"type":"message.send","conversation_id":"c","message_id":"i","content":"/sessions","attachments":[{"id":"ignored"}]}),&context("c","i")).is_err());
    let mut bad = context("c", "i");
    bad.session_id = wire::digest("other");
    assert!(commands::normalize(&frame, &bad).is_err());
    assert!(
        commands::normalize(
            &json!({"type":"message.send","content":"ordinary text"}),
            &context("c", "i")
        )?
        .is_none()
    );
    Ok(())
}
#[tokio::test]
async fn exact_snapshot_replays_after_restart_and_payload_conflicts_fail() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("core.sqlite");
    let c = core(&path)?;
    chat(&c, "c", "chat-1", "first").await?;
    let req = request("c", "read-1", "/session history")?;
    let first = c.execute_session_command(req.clone()).await?;
    assert_eq!(first.data["history"].as_array().unwrap().len(), 2);
    chat(&c, "c", "chat-2", "second").await?;
    assert_eq!(first, c.execute_session_command(req.clone()).await?);
    drop(c);
    let c = core(&path)?;
    assert_eq!(first, c.execute_session_command(req).await?);
    assert!(
        c.execute_session_command(request("c", "read-1", "/sessions")?)
            .await
            .unwrap_err()
            .to_string()
            .contains("payload conflict")
    );
    assert!(
        chat(&c, "c", "read-1", "attempt model ID reuse")
            .await
            .is_err()
    );
    assert!(
        c.reset_for_input(wire::digest("c"), "read-1".into())
            .await
            .is_err()
    );
    assert!(
        c.execute_session_command(request("c", "chat-1", "/sessions")?)
            .await
            .is_err()
    );
    let second = c
        .execute_session_command(request("c", "read-2", "/session history")?)
        .await?;
    assert_eq!(second.data["history"].as_array().unwrap().len(), 4);
    Ok(())
}
#[tokio::test]
async fn owner_conversation_and_generation_are_not_guessable() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("core.sqlite");
    let c = core(&path)?;
    chat(&c, "private", "p1", "secret-other-conversation").await?;
    chat(&c, "c", "c1", "generation-zero").await?;
    c.reset_for_input(wire::digest("c"), "reset-1".into())
        .await?;
    chat(&c, "c", "c2", "generation-one").await?;
    c.reset_for_input(wire::digest("c"), "reset-2".into())
        .await?;
    let list = c
        .execute_session_command(request("c", "list", "/sessions")?)
        .await?;
    assert_eq!(list.data["sessions"].as_array().unwrap().len(), 3);
    assert_eq!(list.data["sessions"][0]["generation"], 2);
    assert_eq!(list.data["sessions"][0]["materialized"], false);
    assert!(!list.frame.to_string().contains(&wire::digest("private")));
    let history = c
        .execute_session_command(request("c", "hist", "/session history 0")?)
        .await?;
    assert!(history.frame.to_string().contains("generation-zero"));
    assert!(!history.frame.to_string().contains("generation-one"));
    assert!(
        request(
            "c",
            "leak",
            &format!("/session history {}", wire::digest("private"))
        )
        .is_err()
    );
    assert!(
        c.execute_session_command(request("c", "future", "/session info 3")?)
            .await
            .is_err()
    );
    assert!(
        Core::new(
            Store::open(&path)?,
            Provider::new("http://127.0.0.1:1".into(), "mock".into(), None, true)?
        )
        .with_session_context("different-owner".into(), CompressionPolicy::default())
        .is_err()
    );
    // A crafted alias route is rejected even though its session ID has the same prefix.
    let db = rusqlite::Connection::open(&path)?;
    db.execute(
        "INSERT INTO routes VALUES(?1,0)",
        [format!("{}.1", wire::digest("c"))],
    )?;
    assert!(
        c.execute_session_command(request("c", "alias", "/session info 1")?)
            .await
            .unwrap_err()
            .to_string()
            .contains("ambiguous")
    );
    Ok(())
}
#[tokio::test]
async fn reset_is_delegated_not_cosmetically_accepted_and_open_is_unsupported() -> Result<()> {
    let d = tempfile::tempdir()?;
    let c = core(&d.path().join("core.sqlite"))?;
    let req = request("c", "reset", "/reset")?;
    assert!(
        c.execute_session_command(req.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("host_action_required")
    );
    let info = c
        .execute_session_command(request("c", "before", "/session info")?)
        .await?;
    assert_eq!(info.data["generation"], 0);
    let actual = c.reset_for_input(wire::digest("c"), "reset".into()).await?;
    let reply = req.host_response("completed", actual)?;
    assert_eq!(reply.frame["type"], "message.reply");
    assert_eq!(reply.data["generation"], 1);
    for (i, kind) in ["session.open", "session.close"].iter().enumerate() {
        let id = format!("unsupported-{i}");
        let r = commands::normalize(
            &json!({"version":1,"type":kind,"request_id":id,"conversation_id":"c"}),
            &context("c", &id),
        )?
        .unwrap();
        let result = c.execute_session_command(r).await?;
        assert_eq!(result.frame["type"], "session.reply");
        assert_eq!(result.status, "error");
        assert_eq!(result.data["code"], "not_supported");
    }
    Ok(())
}
#[tokio::test]
async fn typed_status_is_current_durable_state_and_has_valid_message_bound() -> Result<()> {
    let d = tempfile::tempdir()?;
    let c = core(&d.path().join("core.sqlite"))?;
    let status = |id: &str| {
        commands::normalize(&json!({"version":1,"type":"session.info","request_id":id,"conversation_id":"c","session_id":"c"}),&context("c",id)).unwrap().unwrap()
    };
    assert_eq!(
        c.execute_session_command(status("idle")).await?.status,
        "idle"
    );
    chat(&c, "c", "chat", "done").await?;
    let done = c.execute_session_command(status("done")).await?;
    assert_eq!(done.status, "completed");
    assert!(done.frame["message"].as_str().unwrap().len() <= 4000);
    for (i, kind) in ["command.request", "slash.command"].iter().enumerate() {
        let id = format!("command-{i}");
        let req=commands::normalize(&json!({"version":1,"type":kind,"request_id":id,"conversation_id":"c","command":"session","args":"info"}),&context("c",&id))?.unwrap();
        let result = c.execute_session_command(req).await?;
        assert_eq!(result.frame["type"], "command.reply");
        assert_eq!(result.frame["request_id"], id);
        assert_eq!(result.status, "completed");
    }
    Ok(())
}
#[tokio::test]
async fn bounded_history_is_paged_without_mutating_original_and_capacity_fails_closed() -> Result<()>
{
    let d = tempfile::tempdir()?;
    let path = d.path().join("core.sqlite");
    let c = core(&path)?;
    for i in 0..5 {
        chat(&c, "c", &format!("c{i}"), &"漢".repeat(10_000)).await?;
    }
    let result = c
        .execute_session_command(request("c", "hist", "/session history --limit 50")?)
        .await?;
    assert!(result.frame["content"].as_str().unwrap().len() <= 48 * 1024);
    assert!(result.data["history"][0]["truncated"].as_bool().unwrap());
    assert!(result.data["next_offset"].is_number());
    assert!(
        c.history(wire::digest("c")).await?[0]["content"]
            .as_str()
            .unwrap()
            .len()
            >= 30_000
    );
    let db = rusqlite::Connection::open(&path)?;
    db.execute("UPDATE session_control_totals SET receipts=16384", [])?;
    assert!(
        c.execute_session_command(request("c", "full", "/sessions")?)
            .await
            .unwrap_err()
            .to_string()
            .contains("capacity")
    );
    assert_eq!(
        result,
        c.execute_session_command(request("c", "hist", "/session history --limit 50")?)
            .await?
    );
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM context_command_receipts WHERE input_id='full'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    Ok(())
}
#[tokio::test]
async fn real_http_model_in_flight_does_not_block_read_controls() -> Result<()> {
    use axum::{Json, Router, routing::post};
    use std::sync::Arc;
    use tokio::sync::Notify;
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let (s, r) = (started.clone(), release.clone());
    let app=Router::new().route("/model",post(move || {let(s,r)=(s.clone(),r.clone());async move{s.notify_one();r.notified().await;Json(json!({"choices":[{"message":{"role":"assistant","content":"real-controlled-answer"},"finish_reason":"stop"}]}))}}));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/model", listener.local_addr()?);
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let d = tempfile::tempdir()?;
    let c = Arc::new(
        Core::new(
            Store::open(&d.path().join("core.sqlite"))?,
            Provider::new(url, "controlled-http".into(), None, false)?,
        )
        .with_session_context("fixture-owner".into(), CompressionPolicy::default())?,
    );
    let cc = c.clone();
    let run =
        tokio::spawn(async move { chat(&cc, "c", "running", "hold until controls finish").await });
    started.notified().await;
    let req=commands::normalize(&json!({"version":1,"type":"session.info","request_id":"status","conversation_id":"c","session_id":"c"}),&context("c","status"))?.unwrap();
    let status = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        c.execute_session_command(req),
    )
    .await??;
    assert_eq!(status.status, "running");
    let info = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        c.execute_session_command(request("c", "info", "/session info")?),
    )
    .await??;
    assert_eq!(info.data["status"], "running");
    release.notify_one();
    run.await??;
    server.abort();
    Ok(())
}

/// Invoked only by tests/session_commands_server.py, with a real release server.
#[tokio::test]
#[ignore = "requires co-operating real Orialis server + mobile client from one process tree"]
async fn real_server_commands_fixture() -> Result<()> {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::{
        connect_async,
        tungstenite::{Message, client::IntoClientRequest},
    };
    let url = std::env::var("SESSION_COMMAND_SERVER")?;
    let d = tempfile::tempdir()?;
    let c = core(&d.path().join("core.sqlite"))?;
    let mut request = url.into_client_request()?;
    request.headers_mut().insert(
        "Authorization",
        "Bearer synthetic-session-commands-token".parse()?,
    );
    let (mut ws, _) = connect_async(request).await?;
    ws.send(Message::Text(json!({"version":1,"type":"hello","device_id":"TE_ST_Rust","client":"hermes","plugin_version":"test-fixture","platform":"linux","capabilities":["session.status"]}).to_string().into())).await?;
    let first: Value = serde_json::from_str(ws.next().await.context("hello closed")??.to_text()?)?;
    ensure!(first["type"] == "hello_ack", "no hello ACK");
    ws.send(Message::Text(
        json!({"version":1,"type":"capabilities.hello","capabilities":["session.status"]})
            .to_string()
            .into(),
    ))
    .await?;
    let mut frames = Vec::new();
    let mut count = 0;
    while count < 5 {
        let raw = tokio::time::timeout(std::time::Duration::from_secs(20), ws.next())
            .await?
            .context("WS closed")??;
        if !raw.is_text() {
            continue;
        }
        let frame: Value = serde_json::from_str(raw.to_text()?)?;
        if frame["type"] == "error" {
            bail!("server rejected frame: {frame}");
        }
        if !matches!(
            frame["type"].as_str(),
            Some("message.send" | "session.info")
        ) {
            continue;
        }
        let conv = frame["conversation_id"].as_str().unwrap();
        let id = frame["request_id"]
            .as_str()
            .or(frame["message_id"].as_str())
            .unwrap();
        let req = commands::normalize(&frame, &context(conv, id))?.context("not a command")?;
        let reply = c.execute_session_command(req).await?;
        frames.push(json!({"request":frame,"response":reply.frame}));
        ws.send(Message::Text(reply.frame.to_string().into()))
            .await?;
        count += 1;
    }
    // Exercise actual extension validation/mobile broadcast for both normalized command envelopes.
    for (i, kind) in ["command.request", "slash.command"].iter().enumerate() {
        let id = format!("extension-{i}");
        let frame = json!({"version":1,"type":kind,"conversation_id":"commands-conversation","request_id":id,"command":"session","args":"info"});
        let req = commands::normalize(&frame, &context("commands-conversation", &id))?.unwrap();
        let reply = c.execute_session_command(req).await?;
        frames.push(json!({"request":frame,"response":reply.frame}));
        ws.send(Message::Text(reply.frame.to_string().into()))
            .await?;
    }
    std::fs::write(
        std::env::var("SESSION_COMMAND_FRAMES")?,
        serde_json::to_vec_pretty(&frames)?,
    )?;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    ws.close(None).await?;
    Ok(())
}
use anyhow::{Context, bail};

#[tokio::test]
async fn compatibility_reset_target_and_compact_session_list_are_truthful() -> Result<()> {
    for target in [None, Some("foreign-route"), Some("0")] {
        let mut frame =
            json!({"version":1,"type":"session.reset","conversation_id":"c","request_id":"reset"});
        if let Some(target) = target {
            frame["session_id"] = json!(target);
        }
        assert!(commands::normalize(&frame, &context("c", "reset")).is_err());
    }
    let frame = json!({"version":1,"type":"session.reset","conversation_id":"c","request_id":"reset","session_id":"c"});
    assert_eq!(
        commands::normalize(&frame, &context("c", "reset"))?
            .unwrap()
            .command(),
        &NormalizedCommand::HostReset
    );
    let d = tempfile::tempdir()?;
    let path = d.path().join("core.sqlite");
    let c = core(&path)?;
    for i in 0..21 {
        c.reset_for_input(wire::digest("c"), format!("r{i}"))
            .await?;
    }
    let request = commands::normalize(
        &json!({"version":1,"type":"session.list","request_id":"list","conversation_id":"c"}),
        &context("c", "list"),
    )?
    .unwrap();
    let reply = c.execute_session_command(request).await?;
    let message = reply.frame["message"].as_str().unwrap();
    assert!(message.len() <= 4000);
    let compact: Value = serde_json::from_str(message)?;
    assert!(compact["sessions"].as_array().unwrap().len() > 1);
    assert!(compact["next_offset"].is_number());
    chat(&c, "c", "last", "completed before synthetic crash").await?;
    let db = rusqlite::Connection::open(&path)?;
    db.execute(
        "UPDATE context_turns SET state='active' WHERE input_id='last'",
        [],
    )?;
    drop(c);
    let c = core(&path)?;
    let req=commands::normalize(&json!({"version":1,"type":"session.info","request_id":"after-crash","conversation_id":"c","session_id":"c"}),&context("c","after-crash"))?.unwrap();
    assert_eq!(c.execute_session_command(req).await?.status, "unknown");
    Ok(())
}
#[tokio::test]
async fn real_http_summary_preparation_does_not_report_previous_turn_completed() -> Result<()> {
    use axum::{Json, Router, routing::post};
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::sync::Notify;
    let started = Arc::new(Notify::new());
    let release = Arc::new(Notify::new());
    let calls = Arc::new(AtomicUsize::new(0));
    let (s, r, n) = (started.clone(), release.clone(), calls.clone());
    let app=Router::new().route("/model",post(move || {let(s,r,n)=(s.clone(),r.clone(),n.clone());async move{let call=n.fetch_add(1,Ordering::SeqCst)+1;if call==3{s.notify_one();r.notified().await;}Json(json!({"choices":[{"message":{"role":"assistant","content":"bounded controlled summary or answer"},"finish_reason":"stop"}]}))}}));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
    let url = format!("http://{}/model", listener.local_addr()?);
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let d = tempfile::tempdir()?;
    let policy = CompressionPolicy {
        trigger_messages: 4,
        retain_turns: 1,
        ..CompressionPolicy::default()
    };
    let c = Arc::new(
        Core::new(
            Store::open(&d.path().join("core.sqlite"))?,
            Provider::new(url, "controlled-http-summary".into(), None, false)?,
        )
        .with_session_context("fixture-owner".into(), policy)?,
    );
    for i in 0..2 {
        chat(
            &c,
            "c",
            &format!("before-{i}"),
            &"long context ".repeat(100),
        )
        .await?;
    }
    let cc = c.clone();
    let run = tokio::spawn(async move { chat(&cc, "c", "preparing", "start third turn").await });
    tokio::time::timeout(std::time::Duration::from_secs(3), started.notified()).await?;
    let req=commands::normalize(&json!({"version":1,"type":"session.info","request_id":"during-summary","conversation_id":"c","session_id":"c"}),&context("c","during-summary"))?.unwrap();
    let status = tokio::time::timeout(
        std::time::Duration::from_secs(1),
        c.execute_session_command(req),
    )
    .await??;
    assert_eq!(status.data["durable_state"], "finalized");
    assert_eq!(status.status, "unknown");
    release.notify_one();
    run.await??;
    assert_eq!(calls.load(Ordering::SeqCst), 4);
    server.abort();
    Ok(())
}

#[tokio::test]
async fn first_failed_read_rolls_back_schema_and_reservation_together() -> Result<()> {
    let d = tempfile::tempdir()?;
    let path = d.path().join("core.sqlite");
    let c = core(&path)?;
    assert!(
        c.execute_session_command(request("c", "future", "/session info 9")?)
            .await
            .is_err()
    );
    let db = rusqlite::Connection::open(&path)?;
    assert_eq!(db.query_row("SELECT count(*) FROM sqlite_schema WHERE name IN ('session_control_receipts','session_control_totals')",[],|r|r.get::<_,i64>(0))?,0);
    assert_eq!(
        db.query_row(
            "SELECT count(*) FROM context_command_receipts WHERE input_id='future'",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        0
    );
    let response = c
        .execute_session_command(request("c", "valid", "/session info")?)
        .await?;
    assert_eq!(response.data["generation"], 0);
    assert_eq!(
        db.query_row(
            "SELECT receipts FROM session_control_totals WHERE singleton=1",
            [],
            |r| r.get::<_, i64>(0)
        )?,
        1
    );
    Ok(())
}
