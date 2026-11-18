//! Real pinned Orialis server + agent WS + authenticated mobile WS; no fake
//! event registry, live credentials, model, deployment or production traffic.
use anyhow::{Context, Result, bail};
use futures_util::{SinkExt, StreamExt};
use hermes_rust_core::{
    domain_tools::DomainClient,
    gateway_events::{AckOutcome, FEATURE_CAPABILITIES, GatewayEvents},
    interactions::{InteractionHub, Resolution},
    tool_runtime::TurnContext,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{sync::Arc, time::Duration};
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{Message, client::IntoClientRequest},
};
type Ws = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;
struct Server(std::process::Child);
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
async fn send(ws: &mut Ws, value: &Value) -> Result<()> {
    ws.send(Message::Text(value.to_string().into())).await?;
    Ok(())
}
async fn receive(ws: &mut Ws, kind: &str) -> Result<Value> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            match ws.next().await.context("websocket ended")?? {
                Message::Text(text) => {
                    let v: Value = serde_json::from_str(&text)?;
                    if v["type"] == kind {
                        return Ok(v);
                    }
                    if v["type"] == "error" {
                        bail!("unexpected server error {v}");
                    }
                }
                Message::Ping(bytes) => ws.send(Message::Pong(bytes)).await?,
                _ => {}
            }
        }
    })
    .await
    .context("waiting for real server frame")?
}
async fn mobile_event(ws: &mut Ws, kind: &str, id: &Value) -> Result<Value> {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let v = receive(ws, "event").await?;
            if v["payload"]["event"]["type"] == kind && v["payload"]["event"]["request_id"] == *id {
                return Ok(v);
            }
        }
    })
    .await?
}
async fn next_outbound(events: &GatewayEvents) -> Result<Value> {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(f) = events.pending_after(0, 1).await?.into_iter().next() {
                return Ok(f);
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await?
}
async fn transmit(events: &GatewayEvents, agent: &mut Ws) -> Result<Value> {
    let f = next_outbound(events).await?;
    send(agent, &f).await?;
    let ack = receive(agent, "agent.ack").await?;
    assert_eq!(ack["event_id"], f["event_id"]);
    assert_eq!(ack["status"], "received");
    assert_eq!(events.acknowledge(&ack).await?, AckOutcome::Accepted);
    Ok(f)
}
fn context() -> TurnContext {
    TurnContext {
        conversation_id: "interactive-chat".into(),
        input_id: "input".into(),
        session_id: "trusted-turn-session".into(),
    }
}
async fn mobile_answer(mobile: &mut Ws, request: &Value, kind: &str, answer: Value) -> Result<()> {
    let mut payload = json!({"kind":kind,"conversationId":"interactive-chat"});
    payload[if kind == "approval.response" {
        "decision"
    } else {
        "answer"
    }] = answer;
    send(
        mobile,
        &json!({"version":1,"type":"event","request_id":request["request_id"],"payload":payload}),
    )
    .await
}
#[tokio::test]
#[ignore = "requires ORIALIS_REAL_SERVER_BIN pointing to pinned local server"]
async fn actual_server_mobile_clarify_approve_deny_and_expired_cleanup() -> Result<()> {
    let dir = tempfile::tempdir()?;
    let database = dir.path().join("server.sqlite");
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    let base = format!("http://127.0.0.1:{port}");
    let wsbase = format!("ws://127.0.0.1:{port}");
    let child = std::process::Command::new(std::env::var("ORIALIS_REAL_SERVER_BIN")?)
        .env_clear()
        .env("ORIALIS_HOST", "127.0.0.1")
        .env("ORIALIS_PORT", port.to_string())
        .env("ORIALIS_ENV", "development")
        .env("ORIALIS_DEV_DEVICE_AUTH", "false")
        .env("ORIALIS_PUBLIC_URL", &base)
        .env(
            "ORIALIS_DATABASE_URL",
            format!("sqlite://{}?mode=rwc", database.display()),
        )
        .env("ORIALIS_UPLOAD_DIR", dir.path().join("uploads"))
        .env("ORIALIS_AGENT_DEVICE_TOKEN", "synthetic-agent-token")
        .env("ORIALIS_AGENT_USER_ID", "interaction-owner")
        .env("RUST_LOG", "error")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::inherit())
        .spawn()?;
    let _server = Server(child);
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()?;
    let mut ready = false;
    for _ in 0..100 {
        if http
            .get(format!("{base}/api/v1/health"))
            .send()
            .await
            .is_ok()
        {
            ready = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(ready);
    let db = rusqlite::Connection::open(&database)?;
    db.execute("INSERT INTO users(id,username,password_hash) VALUES('interaction-owner','interaction-owner','synthetic-no-login')",[])?;
    db.execute("INSERT INTO user_sessions(id,user_id,token_hash,expires_at) VALUES('mobile-session','interaction-owner',?1,'2099-01-01T00:00:00Z')",[format!("{:x}",Sha256::digest(b"synthetic-mobile-session"))])?;
    drop(db);
    let events = GatewayEvents::open(&dir.path().join("events.sqlite"), "owner/device").await?;
    let features = FEATURE_CAPABILITIES
        .iter()
        .map(|s| s.to_string())
        .collect::<Vec<_>>();
    events.enable_features(&features).await?;
    let mut req = format!("{wsbase}/api/v1/agent/ws").into_client_request()?;
    req.headers_mut()
        .insert("authorization", "Bearer synthetic-agent-token".parse()?);
    let (mut agent, _) = connect_async(req).await?;
    send(&mut agent,&json!({"version":1,"type":"hello","device_id":"TE_ST_Hermes","client":"orialis-hermes-plugin","plugin_version":"test","platform":"linux","capabilities":features})).await?;
    receive(&mut agent, "hello_ack").await?;
    send(&mut agent, &events.capabilities_hello(&[]).await?).await?;
    let caps = receive(&mut agent, "capabilities.ack").await?;
    events.negotiate(&caps).await?;
    let domain = DomainClient::new(&base, "TE_ST_Hermes", "synthetic-agent-token", None)?;
    assert_eq!(
        domain
            .execute(
                "create_conversation",
                json!({"id":"interactive-chat","title":"Synthetic interaction"})
            )
            .await["ok"],
        true
    );
    let bound = http
        .put(format!(
            "{base}/api/v1/conversations/interactive-chat/agent-device"
        ))
        .header("authorization", "Session synthetic-mobile-session")
        .json(&json!({"deviceId":"TE_ST_Hermes"}))
        .send()
        .await?;
    assert!(bound.status().is_success(), "{}", bound.text().await?);
    let mut req = format!("{wsbase}/api/v1/mobile/ws").into_client_request()?;
    req.headers_mut()
        .insert("authorization", "Session synthetic-mobile-session".parse()?);
    let (mut mobile, _) = connect_async(req).await?;
    send(
        &mut mobile,
        &json!({"version":1,"type":"hello","payload":{}}),
    )
    .await?;
    receive(&mut mobile, "hello.ack").await?;
    let hub = InteractionHub::open(
        &dir.path().join("interactions.sqlite"),
        "owner/device",
        Arc::new(events.clone()),
        Duration::from_secs(3),
    )
    .await?;
    hub.flush().await?;
    let h = hub.clone();
    let clarify = tokio::spawn(async move {
        h.clarify(
            &context(),
            "Pick one or several",
            Some(&["A (Recommended)".into(), "B".into()]),
            true,
        )
        .await
    });
    let request = transmit(&events, &mut agent).await?;
    let card = mobile_event(&mut mobile, "clarify.request", &request["request_id"]).await?;
    assert_eq!(
        card["payload"]["event"]["options"],
        json!(["A (Recommended)", "B"])
    );
    // Evidence of pinned server's current limitation: it drops multi_select.
    assert!(card["payload"]["event"].get("multi_select").is_none());
    mobile_answer(
        &mut mobile,
        &request,
        "clarify.response",
        json!(["A (Recommended)", "Other: own choice"]),
    )
    .await?;
    let answer = receive(&mut agent, "clarify.resolve").await?;
    assert!(answer.get("answer").is_some());
    assert!(answer.get("response").is_none());
    let ack = hub.resolve(&answer).await?;
    send(&mut agent, &ack).await?;
    assert_eq!(
        clarify.await??,
        Resolution::Answer(json!(["A (Recommended)", "Other: own choice"]))
    );
    mobile_event(&mut mobile, "clarify.resolve", &request["request_id"]).await?;
    mobile_answer(&mut mobile, &request, "clarify.response", json!("replayed")).await?;
    let error = receive(&mut mobile, "error").await?;
    assert!(error.to_string().contains("not pending"));
    // Approval is resolved by actual mobile route, accepted only after host ack.
    for decision in ["once", "deny"] {
        let h = hub.clone();
        let job = tokio::spawn(async move {
            h.approve(
                &context(),
                &json!({"operation":"write","target":"local-proof"}),
                "Write local proof",
                "Exact synthetic file only",
            )
            .await
        });
        let request = transmit(&events, &mut agent).await?;
        mobile_event(&mut mobile, "approval.request", &request["request_id"]).await?;
        if decision == "once" {
            mobile_answer(&mut mobile, &request, "approval.response", json!("always")).await?;
            let answer = receive(&mut agent, "approval.resolve").await?;
            assert!(hub.resolve(&answer).await.is_err());
            assert_eq!(hub.pending_count(), 1);
            send(&mut agent,&json!({"version":1,"type":"error","reply_to":request["request_id"],"code":"UNSUPPORTED_APPROVAL_SCOPE","message":"Use once or deny"})).await?;
            receive(&mut mobile, "error").await?;
        }
        mobile_answer(&mut mobile, &request, "approval.response", json!(decision)).await?;
        let answer = receive(&mut agent, "approval.resolve").await?;
        let ack = hub.resolve(&answer).await?;
        send(&mut agent, &ack).await?;
        let result = job.await?;
        if decision == "once" {
            result?.verify(
                &context(),
                &json!({"operation":"write","target":"local-proof"}),
            )?;
            std::fs::write(dir.path().join("local-proof"), "executed once")?;
        } else {
            assert!(result.is_err());
            assert_eq!(
                std::fs::read_to_string(dir.path().join("local-proof"))?,
                "executed once"
            );
        }
        mobile_event(&mut mobile, "approval.resolve", &request["request_id"]).await?;
    }
    // Actual server consumes sequence even when local cleanup finds no pending
    // approval. Preserve unknown; exact replay is duplicate and drains safely.
    events.enqueue_feature(json!({"type":"approval.resolve","request_id":"approval_crash_before_send","conversation_id":"interactive-chat","decision":"cancelled","reason":"restart"})).await?;
    let cleanup = next_outbound(&events).await?;
    send(&mut agent, &cleanup).await?;
    let unknown = receive(&mut agent, "agent.ack").await?;
    assert_eq!(unknown["status"], "unknown");
    assert!(events.acknowledge(&unknown).await.is_err());
    receive(&mut agent, "error").await?;
    send(&mut agent, &cleanup).await?;
    let duplicate = receive(&mut agent, "agent.ack").await?;
    assert_eq!(duplicate["status"], "duplicate");
    assert_eq!(events.acknowledge(&duplicate).await?, AckOutcome::Accepted);
    assert!(events.pending_after(0, 10).await?.is_empty());
    hub.shutdown().await?;
    events.shutdown().await?;
    println!(
        "REAL INTERACTIONS: authentic agent/mobile WS clarify answer+Other, once-only exact action execution, denied action, unsupported always retry, mobile card removal only after host ack, duplicate response rejected, unknown cleanup retained then duplicate replay drained; pinned server drops multi_select."
    );
    Ok(())
}
