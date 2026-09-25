use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    http::HeaderMap,
    response::IntoResponse,
};
use futures_util::StreamExt;
use serde_json::Value;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{broadcast, Mutex};

use crate::{
    agent_gateway::{protocol, protocol::MobileEnvelope, AgentRegistry, RegistryError},
    authenticated_user, AppState,
};

const PROTOCOL_VERSION: u32 = 1;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(20);
const MOBILE_EVENT_BUFFER: usize = 128;

#[derive(Clone, Default)]
pub(crate) struct MobileRegistry {
    channels: Arc<Mutex<HashMap<String, broadcast::Sender<MobileEnvelope>>>>,
}

impl MobileRegistry {
    async fn subscribe(&self, user_id: &str) -> broadcast::Receiver<MobileEnvelope> {
        let mut channels = self.channels.lock().await;
        channels
            .entry(user_id.to_owned())
            .or_insert_with(|| broadcast::channel(MOBILE_EVENT_BUFFER).0)
            .subscribe()
    }

    pub(crate) fn notify(&self, user_id: &str, envelope: MobileEnvelope) {
        let channels = self.channels.clone();
        let user_id = user_id.to_owned();
        tokio::spawn(async move {
            let channels = channels.lock().await;
            if let Some(sender) = channels.get(&user_id) {
                let _ = sender.send(envelope);
            }
        });
    }
}

pub async fn upgrade(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let Ok(user_id) = authenticated_user(&headers, &state.pool).await else {
        return (
            axum::http::StatusCode::UNAUTHORIZED,
            "valid session required",
        )
            .into_response();
    };
    ws.on_upgrade(move |socket| handle_socket(socket, state, user_id))
        .into_response()
}

async fn handle_socket(mut socket: WebSocket, state: Arc<AppState>, user_id: String) {
    let Some(Ok(Message::Text(text))) = tokio::time::timeout(HANDSHAKE_TIMEOUT, socket.next())
        .await
        .ok()
        .flatten()
    else {
        return;
    };
    let Ok(hello) = serde_json::from_str::<MobileEnvelope>(text.as_str()) else {
        let _ = send_error(
            &mut socket,
            None,
            "invalid_json",
            "first message must be hello",
        )
        .await;
        return;
    };
    if hello.version != PROTOCOL_VERSION
        || hello.message_type != "hello"
        || !hello.payload.is_object()
    {
        let _ = send_error(
            &mut socket,
            hello.request_id,
            "invalid_hello",
            "first message must be a valid hello envelope",
        )
        .await;
        return;
    }
    let connection_id = uuid::Uuid::now_v7().to_string();
    if send_envelope(
        &mut socket,
        MobileEnvelope {
            version: PROTOCOL_VERSION,
            message_type: "hello.ack".into(),
            request_id: hello.request_id,
            payload: serde_json::json!({ "connection_id": connection_id }),
        },
    )
    .await
    .is_err()
    {
        return;
    }

    let mut updates = state.mobile.subscribe(&user_id).await;
    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    heartbeat.tick().await;
    loop {
        tokio::select! {
            incoming = socket.next() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    if handle_text(&mut socket, &state, &user_id, text.as_str()).await.is_err() { break; }
                }
                Some(Ok(Message::Ping(payload))) => {
                    if socket.send(Message::Pong(payload)).await.is_err() { break; }
                }
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {}
                Some(Err(_)) => break,
            },
            update = updates.recv() => match update {
                Ok(envelope) => {
                    if send_envelope(&mut socket, envelope).await.is_err() { break; }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    let _ = send_error(
                        &mut socket,
                        None,
                        "sync_lagged",
                        "some realtime updates were skipped; run incremental sync",
                    ).await;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            _ = heartbeat.tick() => {
                let ping = MobileEnvelope {
                    version: PROTOCOL_VERSION,
                    message_type: "ping".into(),
                    request_id: None,
                    payload: serde_json::json!({}),
                };
                if send_envelope(&mut socket, ping).await.is_err() { break; }
            }
        }
    }
}

async fn handle_text(
    socket: &mut WebSocket,
    state: &Arc<AppState>,
    user_id: &str,
    text: &str,
) -> Result<(), ()> {
    let envelope = serde_json::from_str::<MobileEnvelope>(text).map_err(|_| ())?;
    if envelope.version != PROTOCOL_VERSION || !envelope.payload.is_object() {
        return send_error(
            socket,
            envelope.request_id,
            "invalid_message",
            "invalid mobile envelope",
        )
        .await;
    }
    match envelope.message_type.as_str() {
        "ping" => {
            send_envelope(
                socket,
                MobileEnvelope {
                    version: PROTOCOL_VERSION,
                    message_type: "pong".into(),
                    request_id: envelope.request_id,
                    payload: serde_json::json!({}),
                },
            )
            .await
        }
        "pong" | "message" | "sync.change_hint" => Ok(()),
        "event" => handle_agent_event(socket, state, user_id, &envelope).await,
        _ => {
            send_error(
                socket,
                envelope.request_id,
                "invalid_message",
                "message type is not supported",
            )
            .await
        }
    }
}

async fn handle_agent_event(
    socket: &mut WebSocket,
    state: &Arc<AppState>,
    user_id: &str,
    envelope: &MobileEnvelope,
) -> Result<(), ()> {
    let kind = envelope
        .payload
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let conversation_id = envelope
        .payload
        .get("conversationId")
        .and_then(Value::as_str)
        .unwrap_or("default")
        .to_owned();
    let request_id = envelope
        .request_id
        .clone()
        .unwrap_or_else(|| format!("mobile_{}", uuid::Uuid::now_v7()));
    let session_id = envelope
        .payload
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or(&conversation_id)
        .to_owned();

    let result = match kind {
        "clarify.response" => {
            let answer = envelope
                .payload
                .get("answer")
                .cloned()
                .unwrap_or_else(|| Value::String(String::new()));
            let message = protocol::GatewayMessage::ClarifyResolve {
                version: protocol::PROTOCOL_VERSION,
                event_id: format!("mobile-event-{}", uuid::Uuid::now_v7()),
                seq: 0,
                session_id,
                request_id: request_id.clone(),
                answer,
            };
            state
                .agent
                .send_event_for_user(user_id, None, message)
                .await
                .map(|_| ())
                .map_err(registry_error_message)
        }
        "approval.response" => {
            let decision = match envelope
                .payload
                .get("decision")
                .and_then(Value::as_str)
                .unwrap_or("deny")
            {
                "once" => protocol::ApprovalDecision::Once,
                "session" => protocol::ApprovalDecision::Session,
                "always" => protocol::ApprovalDecision::Always,
                "deny" => protocol::ApprovalDecision::Deny,
                _ => {
                    return send_error(
                        socket,
                        Some(request_id),
                        "invalid_approval_decision",
                        "approval decision must be once, session, always, or deny",
                    )
                    .await;
                }
            };
            let message = protocol::GatewayMessage::ApprovalResolve {
                version: protocol::PROTOCOL_VERSION,
                event_id: format!("mobile-event-{}", uuid::Uuid::now_v7()),
                seq: 0,
                session_id,
                request_id: request_id.clone(),
                decision,
                reason: envelope
                    .payload
                    .get("reason")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            };
            state
                .agent
                .send_event_for_user(user_id, None, message)
                .await
                .map(|_| ())
                .map_err(registry_error_message)
        }
        "hermes.command" => {
            let command = envelope
                .payload
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_owned();
            if command.is_empty() {
                return send_error(
                    socket,
                    Some(request_id),
                    "invalid_command",
                    "command must not be empty",
                )
                .await;
            }
            let message_id = request_id.clone();
            let content = if command.starts_with('/') {
                command.clone()
            } else {
                format!("/{command}")
            };
            let response = run_session_command(
                &state.agent,
                user_id,
                &conversation_id,
                &message_id,
                &content,
            )
            .await;
            let payload = match response {
                Ok(output) => {
                    serde_json::json!({
                        "kind": "hermes.command.result",
                        "id": request_id,
                        "command": command,
                        "status": "completed",
                        "content": output,
                    })
                }
                Err(error) => serde_json::json!({
                    "kind": "hermes.command.result",
                    "id": request_id,
                    "command": command,
                    "status": "failed",
                    "content": error,
                }),
            };
            return send_envelope(socket, protocol::mobile_event(payload)).await;
        }
        "session.create" | "session.reset" | "session.resume" | "session.status"
        | "session.title" | "session.retry" | "session.stop" => {
            let title = envelope
                .payload
                .get("title")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty());
            if kind == "session.title" && title.is_none() {
                return send_error(
                    socket,
                    Some(request_id),
                    "invalid_session_title",
                    "session title must not be empty",
                )
                .await;
            }
            let command = match kind {
                // Hermes treats /new and /reset as aliases; keep both so the
                // mobile labels match the slash command that actually runs.
                "session.create" => match title {
                    Some(title) => format!("/new {title}"),
                    None => "/new".to_owned(),
                },
                "session.reset" => "/reset".to_owned(),
                "session.resume" => "/resume".to_owned(),
                "session.status" => "/status".to_owned(),
                "session.title" => format!("/title {}", title.unwrap_or_default()),
                // Recovery actions for a failed turn ("request was not processed").
                "session.retry" => "/retry".to_owned(),
                "session.stop" => "/stop".to_owned(),
                _ => unreachable!(),
            };
            return match run_session_command(
                &state.agent,
                user_id,
                &conversation_id,
                &request_id,
                &command,
            )
            .await
            {
                Ok(content) => {
                    send_envelope(
                        socket,
                        protocol::mobile_event(serde_json::json!({
                            "kind": "session.status",
                            "id": session_id,
                            "event": kind,
                            "command": command,
                            "status": "completed",
                            "message": content,
                        })),
                    )
                    .await
                }
                Err(error) => {
                    send_error(socket, Some(request_id), "agent_unavailable", &error).await
                }
            };
        }
        "delivery.notification" => Ok(()),
        _ => {
            return send_error(
                socket,
                Some(request_id),
                "unsupported_agent_action",
                "this Agent action is not supported by the connected Orialis Server",
            )
            .await;
        }
    };

    if let Err(error) = result {
        return send_error(socket, Some(request_id), "agent_unavailable", &error).await;
    }
    Ok(())
}

async fn send_agent_request(
    agent: &AgentRegistry,
    user_id: &str,
    message: protocol::GatewayMessage,
) -> Result<protocol::GatewayMessage, String> {
    let receiver = agent
        .send_request_for_user(user_id, None, message)
        .await
        .map_err(registry_error_message)?;
    tokio::time::timeout(Duration::from_secs(60), receiver)
        .await
        .map_err(|_| "Agent response timed out".to_owned())?
        .map_err(|_| "Agent connection closed before responding".to_owned())
}

/// True when Hermes answered a destructive slash command with its confirm prompt
/// instead of running it. Session-control buttons are already the user's intent,
/// so the follow-up `/approve` below completes the action without a second dialog.
fn looks_like_slash_confirm(content: &str) -> bool {
    let lower = content.to_ascii_lowercase();
    lower.contains("confirm /") && (lower.contains("approve") || lower.contains("cancel"))
}

async fn run_session_command(
    agent: &AgentRegistry,
    user_id: &str,
    conversation_id: &str,
    request_id: &str,
    command: &str,
) -> Result<String, String> {
    let send = |message_id: String, content: String| protocol::GatewayMessage::MessageSend {
        version: protocol::PROTOCOL_VERSION,
        message_id,
        conversation_id: conversation_id.to_owned(),
        content,
        attachments: vec![],
    };
    let first = send_agent_request(
        agent,
        user_id,
        send(format!("{request_id}"), command.to_owned()),
    )
    .await?;
    let content = match first {
        protocol::GatewayMessage::MessageReply { content, .. } => content,
        _ => return Err("Agent returned an unexpected session response".to_owned()),
    };
    if !looks_like_slash_confirm(&content) {
        return Ok(content);
    }
    // Complete the pending destructive confirm that Hermes just raised.
    let approved = send_agent_request(
        agent,
        user_id,
        send(format!("{request_id}-approve"), "/approve".to_owned()),
    )
    .await?;
    match approved {
        protocol::GatewayMessage::MessageReply { content, .. } => Ok(content),
        _ => Err("Agent returned an unexpected session confirm response".to_owned()),
    }
}

fn registry_error_message(error: RegistryError) -> String {
    match error {
        RegistryError::NoConnection => "no Orialis Hermes plugin is connected".to_owned(),
        RegistryError::ConnectionClosed => "Orialis Hermes plugin connection closed".to_owned(),
        RegistryError::DuplicateMessage => "request has already been processed".to_owned(),
    }
}

async fn send_error(
    socket: &mut WebSocket,
    request_id: Option<String>,
    code: &str,
    message: &str,
) -> Result<(), ()> {
    send_envelope(
        socket,
        MobileEnvelope {
            version: PROTOCOL_VERSION,
            message_type: "error".into(),
            request_id,
            payload: serde_json::json!({ "code": code, "message": message }),
        },
    )
    .await
}

async fn send_envelope(socket: &mut WebSocket, envelope: MobileEnvelope) -> Result<(), ()> {
    let text = serde_json::to_string(&envelope).map_err(|_| ())?;
    socket
        .send(Message::Text(text.into()))
        .await
        .map_err(|_| ())
}

#[cfg(test)]
mod session_control_tests {
    use super::looks_like_slash_confirm;

    #[test]
    fn detects_destructive_slash_confirm_prompts() {
        assert!(looks_like_slash_confirm(
            "⚠️ **Confirm /new**\n\nThis starts a fresh session.\n\nChoose:\n• **Approve Once**\n• **Cancel**"
        ));
        assert!(looks_like_slash_confirm(
            "Confirm /reset — choose Approve or Cancel"
        ));
    }

    #[test]
    fn ignores_ordinary_session_replies() {
        assert!(!looks_like_slash_confirm("Started a fresh session."));
        assert!(!looks_like_slash_confirm("/status · model ready"));
        assert!(!looks_like_slash_confirm("Your request was not processed."));
    }
}
