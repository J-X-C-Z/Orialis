use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    http::HeaderMap,
    response::IntoResponse,
};
use futures_util::StreamExt;
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::broadcast;

use crate::{
    agent_gateway::{protocol, protocol::MobileEnvelope, AgentRegistry, RegistryError},
    authenticated_user, AppState,
};

const PROTOCOL_VERSION: u32 = 1;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(20);
const MOBILE_EVENT_BUFFER: usize = 128;

fn mobile_heartbeat() -> MobileEnvelope {
    protocol::mobile_envelope(protocol::MOBILE_PING, None, serde_json::json!({}))
}

#[derive(Clone, Default)]
pub(crate) struct MobileRegistry {
    channels: Arc<Mutex<HashMap<String, MobileChannel>>>,
}

struct PendingMobile {
    envelope: MobileEnvelope,
    expires_at: Instant,
    inserted_at: Instant,
}

struct MobileChannel {
    sender: broadcast::Sender<MobileEnvelope>,
    pending: HashMap<String, PendingMobile>,
    resolved: HashSet<String>,
    resolved_order: VecDeque<String>,
}

impl Default for MobileChannel {
    fn default() -> Self {
        Self {
            sender: broadcast::channel(MOBILE_EVENT_BUFFER).0,
            pending: HashMap::new(),
            resolved: HashSet::new(),
            resolved_order: VecDeque::new(),
        }
    }
}

/// Normalize only interaction identity; retain the original event for replay.
fn interaction_identity(envelope: &MobileEnvelope) -> Option<(String, String, String, bool, u64)> {
    let outer = &envelope.payload;
    let event = if outer["kind"] == "agent_gateway_event" {
        &outer["event"]
    } else {
        outer
    };
    let nested = event.get("payload").unwrap_or(event);
    let kind = event["event_type"]
        .as_str()
        .or_else(|| event["type"].as_str())
        .or_else(|| event["kind"].as_str())?;
    let family = if kind.starts_with("approval.") {
        "approval"
    } else if kind.starts_with("clarify.") {
        "clarify"
    } else {
        return None;
    };
    let request = nested["request_id"]
        .as_str()
        .or_else(|| nested["requestId"].as_str())
        .or_else(|| nested["id"].as_str())
        .or(envelope.request_id.as_deref())?;
    let conversation = outer["conversationId"]
        .as_str()
        .or_else(|| nested["conversation_id"].as_str())
        .or_else(|| nested["conversationId"].as_str())
        .or_else(|| nested["session_id"].as_str())
        .or_else(|| event["session_id"].as_str())
        .unwrap_or_default();
    if request.is_empty() || request.len() > 200 || conversation.len() > 200 {
        return None;
    }
    let pending = matches!(
        kind,
        "approval.request" | "approval.requested" | "clarify.request" | "clarify.requested"
    );
    if !pending
        && !matches!(
            kind,
            "approval.resolve"
                | "approval.resolved"
                | "approval.response"
                | "approval.responded"
                | "approval.cancel"
                | "approval.timeout"
                | "clarify.resolve"
                | "clarify.resolved"
                | "clarify.response"
                | "clarify.responded"
                | "clarify.cancel"
                | "clarify.timeout"
        )
    {
        return None;
    }
    let timeout = nested["timeout_ms"]
        .as_u64()
        .unwrap_or(if family == "approval" {
            120_000
        } else {
            300_000
        })
        .clamp(1, 86_400_000);
    Some((
        family.into(),
        request.into(),
        conversation.into(),
        pending,
        timeout,
    ))
}

impl MobileRegistry {
    fn has_pending(&self, user_id: &str, request_id: &str, conversation_id: &str) -> bool {
        let channels = self
            .channels
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        channels.get(user_id).is_some_and(|channel| {
            channel.pending.values().any(|pending| {
                pending.expires_at > Instant::now()
                    && interaction_identity(&pending.envelope).is_some_and(
                        |(_, request, conversation, active, _)| {
                            active && request == request_id && conversation == conversation_id
                        },
                    )
            })
        })
    }
    async fn subscribe(
        &self,
        user_id: &str,
    ) -> (broadcast::Receiver<MobileEnvelope>, Vec<MobileEnvelope>) {
        let mut channels = self
            .channels
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let channel = channels.entry(user_id.to_owned()).or_default();
        channel
            .pending
            .retain(|_, pending| pending.expires_at > Instant::now());
        let receiver = channel.sender.subscribe();
        let mut pending = channel.pending.values().collect::<Vec<_>>();
        pending.sort_by_key(|value| value.inserted_at);
        (
            receiver,
            pending
                .into_iter()
                .map(|value| value.envelope.clone())
                .collect(),
        )
    }

    pub(crate) fn notify(&self, user_id: &str, envelope: MobileEnvelope) {
        let mut channels = self
            .channels
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let channel = channels.entry(user_id.to_owned()).or_default();
        if let Some((family, request, conversation, pending, timeout)) =
            interaction_identity(&envelope)
        {
            let resolved_key = serde_json::json!([family, request]).to_string();
            let key = format!("{resolved_key}:{conversation}");
            if pending {
                if channel.resolved.contains(&resolved_key) {
                    return;
                }
                channel
                    .pending
                    .retain(|_, value| value.expires_at > Instant::now());
                if !channel.pending.contains_key(&key)
                    && channel.pending.len() >= MOBILE_EVENT_BUFFER
                {
                    if let Some(oldest) = channel
                        .pending
                        .iter()
                        .min_by_key(|(_, value)| value.inserted_at)
                        .map(|(key, _)| key.clone())
                    {
                        channel.pending.remove(&oldest);
                    }
                }
                channel.pending.entry(key).or_insert_with(|| PendingMobile {
                    envelope: envelope.clone(),
                    expires_at: Instant::now() + Duration::from_millis(timeout),
                    inserted_at: Instant::now(),
                });
            } else {
                channel
                    .pending
                    .retain(|key, _| !key.starts_with(&format!("{resolved_key}:")));
                if channel.resolved.insert(resolved_key.clone()) {
                    channel.resolved_order.push_back(resolved_key);
                    if channel.resolved_order.len() > 1024 {
                        if let Some(oldest) = channel.resolved_order.pop_front() {
                            channel.resolved.remove(&oldest);
                        }
                    }
                }
            }
        }
        let _ = channel.sender.send(envelope);
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

    let (mut updates, pending) = state.mobile.subscribe(&user_id).await;
    for envelope in pending {
        if send_envelope(&mut socket, envelope).await.is_err() {
            return;
        }
    }
    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    heartbeat.tick().await;
    loop {
        tokio::select! {
            incoming = socket.next() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    if handle_text(&mut socket, &state, &user_id, &connection_id, text.as_str()).await.is_err() { break; }
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
                if send_envelope(&mut socket, mobile_heartbeat()).await.is_err() { break; }
            }
        }
    }
    // A mobile socket owns its PTYs. Closing it must not leave remote shells
    // alive; the host's idle lease also handles an unreachable server.
    for agent in state.agent.online_agents(&user_id).await {
        let wire_id = format!("workspace_{}", uuid::Uuid::now_v7());
        let payload = serde_json::json!({"op":"terminal.close_client","_clientId":connection_id});
        if let Ok(receiver) = state
            .agent
            .send_request_for_user(
                &user_id,
                Some(&agent.device_id),
                protocol::GatewayMessage::WorkspaceRequest {
                    version: PROTOCOL_VERSION,
                    request_id: wire_id.clone(),
                    conversation_id: "_connection".into(),
                    payload,
                },
            )
            .await
        {
            let _ = tokio::time::timeout(Duration::from_secs(2), receiver).await;
            state.agent.cancel_request(&wire_id).await;
        }
    }
}

async fn handle_text(
    socket: &mut WebSocket,
    state: &Arc<AppState>,
    user_id: &str,
    client_id: &str,
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
        "event" => handle_agent_event(socket, state, user_id, client_id, &envelope).await,
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
    client_id: &str,
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

    if kind == "workspace.request" {
        let request_id = envelope
            .payload
            .get("requestId")
            .and_then(Value::as_str)
            .unwrap_or(&request_id)
            .to_owned();
        let op = envelope
            .payload
            .get("op")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let mut request = envelope.payload.clone();
        request["_clientId"] = Value::String(client_id.into());
        // Internal disconnect cleanup is never callable by a mobile payload.
        let result = if op == "terminal.close_client" || op == "terminal.close_all" {
            Err("Unsupported workspace operation".into())
        } else {
            workspace_request(state, user_id, &conversation_id, &request_id, request).await
        };
        let mut payload = match result {
            Ok(payload) => payload,
            Err(message) => {
                serde_json::json!({"ok":false,"error":{"code":"workspace_unavailable","message":message}})
            }
        };
        payload["kind"] = Value::String("workspace.response".into());
        payload["conversationId"] = Value::String(conversation_id);
        payload["requestId"] = Value::String(request_id);
        payload["op"] = Value::String(op.into());
        return send_envelope(socket, protocol::mobile_event(payload)).await;
    }

    let target_device_id = if matches!(kind, "clarify.response" | "approval.response") {
        match crate::conversation_agent_device(&state.pool, user_id, &conversation_id).await {
            Ok(device_id) => device_id,
            Err(error) => {
                return send_error(
                    socket,
                    Some(request_id),
                    "agent_unavailable",
                    &format!("conversation routing unavailable: {error:?}"),
                )
                .await
            }
        }
    } else {
        None
    };

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
                session_id: conversation_id.clone(),
                request_id: request_id.clone(),
                answer,
            };
            resolve_mobile_interaction(
                state,
                user_id,
                target_device_id.as_deref(),
                &conversation_id,
                message,
            )
            .await
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
                session_id: conversation_id.clone(),
                request_id: request_id.clone(),
                decision,
                reason: envelope
                    .payload
                    .get("reason")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
            };
            resolve_mobile_interaction(
                state,
                user_id,
                target_device_id.as_deref(),
                &conversation_id,
                message,
            )
            .await
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
            let response =
                run_session_command(state, user_id, &conversation_id, &message_id, &content).await;
            let payload = match response {
                Ok(output) => {
                    serde_json::json!({
                        "kind": "hermes.command.result",
                        "conversationId": conversation_id,
                        "id": request_id,
                        "command": command,
                        "status": "completed",
                        "content": output,
                    })
                }
                Err(error) => serde_json::json!({
                    "kind": "hermes.command.result",
                    "conversationId": conversation_id,
                    "id": request_id,
                    "command": command,
                    "status": "failed",
                    "content": error,
                }),
            };
            return send_envelope(socket, protocol::mobile_event(payload)).await;
        }
        "session.status" => {
            return match run_session_status(state, user_id, &conversation_id, &request_id, &session_id).await {
                Ok(payload) => send_envelope(socket, protocol::mobile_event(payload)).await,
                Err(error) => send_error(socket, Some(request_id), "agent_unavailable", &error).await,
            };
        }
        "session.create" | "session.reset" | "session.resume"
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
                "session.title" => format!("/title {}", title.unwrap_or_default()),
                // Recovery actions for a failed turn ("request was not processed").
                "session.retry" => "/retry".to_owned(),
                "session.stop" => "/stop".to_owned(),
                _ => unreachable!(),
            };
            return match run_session_command(
                state,
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
                            "requestId": request_id,
                            "conversationId": conversation_id,
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

/// A transport enqueue is not an interaction result. Keep the replayable
/// request until this exact host acknowledges its resolver succeeded.
async fn resolve_mobile_interaction(
    state: &AppState,
    user_id: &str,
    device_id: Option<&str>,
    conversation_id: &str,
    message: protocol::GatewayMessage,
) -> Result<(), String> {
    let request_id = message
        .message_id()
        .ok_or("Missing interaction request ID")?
        .to_owned();
    let device_id = device_id.ok_or("Bind the conversation to its Hermes device first")?;
    if !state
        .mobile
        .has_pending(user_id, &request_id, conversation_id)
    {
        return Err("Interaction is not pending in this conversation".into());
    }
    let receiver = state
        .agent
        .send_request_for_user(user_id, Some(device_id), message.clone())
        .await
        .map_err(registry_error_message)?;
    let result = tokio::time::timeout(Duration::from_secs(15), receiver).await;
    state.agent.cancel_request(&request_id).await;
    match result {
        Ok(Ok(protocol::GatewayMessage::MessageAck { status, .. })) if status == "resolved" => {
            state.mobile.notify(
                user_id,
                protocol::mobile_event(serde_json::json!({
                    "kind":"agent_gateway_event", "conversationId":conversation_id, "event":message,
                })),
            );
            Ok(())
        }
        Ok(Ok(
            protocol::GatewayMessage::ApprovalResolve { .. }
            | protocol::GatewayMessage::ClarifyResolve { .. },
        )) => Ok(()),
        Ok(Ok(protocol::GatewayMessage::Error { code, message, .. })) => {
            Err(format!("{code}: {message}"))
        }
        Ok(Ok(_)) => Err("Hermes did not acknowledge the interaction resolver".into()),
        Ok(Err(_)) => Err("Hermes disconnected; interaction remains pending".into()),
        Err(_) => Err("Hermes acknowledgement timed out; interaction remains pending".into()),
    }
}

/// Workspace access requires an explicit owned conversation binding, including
/// capabilities probes. There is deliberately no fallback to another Agent.
pub(crate) async fn workspace_request(
    state: &AppState,
    user_id: &str,
    conversation_id: &str,
    request_id: &str,
    payload: Value,
) -> Result<Value, String> {
    if request_id.trim().is_empty()
        || request_id.len() > 160
        || conversation_id.len() > 160
        || !payload.is_object()
        || payload.to_string().len() > 1_500_000
    {
        return Err("Invalid workspace request".into());
    }
    let device: Option<String> = sqlx::query_scalar::<_, Option<String>>(
        "SELECT c.agent_device_id FROM conversations c JOIN agent_devices d ON d.device_id=c.agent_device_id AND d.user_id=c.user_id WHERE c.user_id=? AND c.id=? AND c.deleted_at IS NULL"
    ).bind(user_id).bind(conversation_id).fetch_optional(&state.pool).await
        .map_err(|_| "Unable to verify conversation ownership".to_owned())?.flatten();
    let device = device.ok_or("Bind this conversation to an owned Hermes device first")?;
    let wire_id = format!("workspace_{}", uuid::Uuid::now_v7());
    let receiver = state
        .agent
        .send_request_for_user(
            user_id,
            Some(&device),
            protocol::GatewayMessage::WorkspaceRequest {
                version: PROTOCOL_VERSION,
                request_id: wire_id.clone(),
                conversation_id: conversation_id.into(),
                payload,
            },
        )
        .await
        .map_err(registry_error_message)?;
    let reply = tokio::time::timeout(Duration::from_secs(15), receiver).await;
    state.agent.cancel_request(&wire_id).await;
    match reply {
        Ok(Ok(protocol::GatewayMessage::WorkspaceResponse {
            conversation_id: reply_conversation,
            payload,
            ..
        })) if reply_conversation == conversation_id => Ok(payload),
        Ok(Ok(protocol::GatewayMessage::Error { message, .. })) => Err(message),
        Ok(Ok(_)) => Err("Invalid workspace response".into()),
        Ok(Err(_)) => Err("Hermes disconnected".into()),
        Err(_) => Err("Hermes did not respond; its workspace capability may be unavailable".into()),
    }
}

async fn send_agent_request(
    agent: &AgentRegistry,
    user_id: &str,
    device_id: Option<&str>,
    message: protocol::GatewayMessage,
) -> Result<protocol::GatewayMessage, String> {
    let receiver = agent
        .send_request_for_user(user_id, device_id, message)
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

async fn run_session_status(
    state: &AppState,
    user_id: &str,
    conversation_id: &str,
    request_id: &str,
    session_id: &str,
) -> Result<Value, String> {
    let device = crate::conversation_agent_device(&state.pool, user_id, conversation_id)
        .await.map_err(|_| "Unable to verify conversation ownership".to_owned())?
        .ok_or("Bind this conversation to an owned Hermes device first")?;
    let (status, message) = if state.agent.supports_for_user(user_id, &device, "session.status").await {
        let wire_id = format!("status_{}", uuid::Uuid::now_v7());
        let receiver = state.agent.send_request_for_user(user_id, Some(&device), protocol::GatewayMessage::SessionInfo {
            version: PROTOCOL_VERSION, request_id: wire_id.clone(),
            conversation_id: conversation_id.into(), session_id: conversation_id.into(),
        }).await.map_err(registry_error_message)?;
        let response = tokio::time::timeout(Duration::from_secs(10), receiver).await;
        state.agent.cancel_request(&wire_id).await;
        match response {
            Ok(Ok(protocol::GatewayMessage::SessionReply { conversation_id: reply_chat, status, message, .. }))
                if reply_chat == conversation_id && matches!(status.as_str(), "running" | "completed" | "error" | "cancelled" | "idle" | "unknown") => (status, message.unwrap_or_default()),
            Ok(Ok(protocol::GatewayMessage::Error { message, .. })) => return Err(message),
            Ok(Ok(_)) => return Err("Invalid Hermes status response".into()),
            Ok(Err(_)) => return Err("Hermes disconnected".into()),
            Err(_) => return Err("Hermes status request timed out".into()),
        }
    } else {
        ("unknown".into(), "当前设备尚未提供实时处理状态，请更新设备端插件。".into())
    };
    Ok(serde_json::json!({
        "kind": "session.status", "requestId": request_id, "conversationId": conversation_id,
        "id": session_id, "event": "session.status", "status": status, "message": message,
    }))
}

async fn run_session_command(
    state: &AppState,
    user_id: &str,
    conversation_id: &str,
    request_id: &str,
    command: &str,
) -> Result<String, String> {
    let device_id = crate::conversation_agent_device(&state.pool, user_id, conversation_id)
        .await
        .map_err(|error| format!("conversation routing unavailable: {error:?}"))?;
    let send = |message_id: String, content: String| protocol::GatewayMessage::MessageSend {
        version: protocol::PROTOCOL_VERSION,
        message_id,
        conversation_id: conversation_id.to_owned(),
        content,
        attachments: vec![],
    };
    let first = send_agent_request(
        &state.agent,
        user_id,
        device_id.as_deref(),
        send(request_id.to_owned(), command.to_owned()),
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
        &state.agent,
        user_id,
        device_id.as_deref(),
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
mod mobile_connection_tests {
    use super::*;

    #[tokio::test]
    async fn session_status_uses_owned_negotiated_info_reply_and_correlates_mobile_request() {
        use crate::agent_gateway::{protocol::GatewayMessage, AgentCommand};
        use crate::conversation_routing_tests::{bind, memory_state};
        let state = memory_state().await;
        let _ = bind(&state, "mac-chat", "mac").await.unwrap();
        let (tx, mut rx) = tokio::sync::mpsc::channel(4);
        state.agent.register_connection("cm-status".into(), "u1".into(), "mac".into(), "macos".into(), tx).await;
        state.agent.set_peer_capabilities("mac", vec!["session.status".into()]).await;
        assert!(!state.agent.supports_for_user("u2", "mac", "session.status").await);
        for status in ["running", "completed", "error", "cancelled"] {
            let task_state = state.clone();
            let task = tokio::spawn(async move {
                run_session_status(&task_state, "u1", "mac-chat", "mobile-refresh", "visible-session").await
            });
            let AgentCommand::Send(request) = rx.recv().await.unwrap() else { panic!("expected request"); };
            let encoded = serde_json::to_string(&request).unwrap();
            let GatewayMessage::SessionInfo { request_id, conversation_id, .. } = protocol::parse_message(&encoded).unwrap() else { panic!("status must not submit a model message"); };
            let reply = serde_json::json!({"version":1,"type":"session.reply","request_id":request_id,"conversation_id":conversation_id,"status":status,"message":"公开进度摘要"});
            let reply = protocol::parse_message(&reply.to_string()).unwrap();
            assert!(!state.agent.resolve_reply_for_device("aozora", reply.clone()).await);
            assert!(state.agent.resolve_reply_for_device("mac", reply).await);
            let response = task.await.unwrap().unwrap();
            assert_eq!(response["kind"], "session.status");
            assert_eq!(response["requestId"], "mobile-refresh");
            assert_eq!(response["conversationId"], "mac-chat");
            assert_eq!(response["status"], status);
            assert_eq!(response["message"], "公开进度摘要");
        }
        assert_eq!(sqlx::query_scalar::<_, i64>("SELECT count(*) FROM messages").fetch_one(&state.pool).await.unwrap(), 0);
        state.agent.remove_connection("cm-status").await;
        assert!(!state.agent.supports_for_user("u1", "mac", "session.status").await);
    }

    #[tokio::test]
    async fn session_status_legacy_peer_returns_unknown_without_dispatching_or_prompting() {
        use crate::conversation_routing_tests::{bind, memory_state};
        let state = memory_state().await;
        let _ = bind(&state, "mac-chat", "mac").await.unwrap();
        let (tx, mut rx) = tokio::sync::mpsc::channel(1);
        state.agent.register_connection("legacy-status".into(), "u1".into(), "mac".into(), "macos".into(), tx).await;
        let response = run_session_status(&state, "u1", "mac-chat", "legacy-refresh", "mac-chat").await.unwrap();
        assert!(rx.try_recv().is_err());
        assert_eq!(response["status"], "unknown");
        assert_eq!(response["requestId"], "legacy-refresh");
        assert_eq!(response["conversationId"], "mac-chat");
        assert_eq!(response["message"], "当前设备尚未提供实时处理状态，请更新设备端插件。");
    }

    #[tokio::test]
    async fn pending_interactions_replay_without_gaps_and_remain_account_scoped() {
        let registry = MobileRegistry::default();
        let approval = protocol::mobile_event(
            serde_json::json!({"kind":"agent_gateway_event", "conversationId":"chat-a",
            "event":{"type":"approval.request","request_id":"a1","action":"write","session_id":"runtime-session"}}),
        );
        let clarify = protocol::mobile_event(
            serde_json::json!({"kind":"clarify.request","conversationId":"chat-b","requestId":"q1","question":"Which?"}),
        );
        registry.notify("alice", approval.clone());
        registry.notify("alice", clarify.clone());
        let (mut receiver, pending) = registry.subscribe("alice").await;
        assert_eq!(pending, vec![approval.clone(), clarify.clone()]);
        assert!(receiver.try_recv().is_err()); // Snapshot is not also queued.
        let (_, foreign) = registry.subscribe("bob").await;
        assert!(foreign.is_empty());
        registry.notify("alice", protocol::mobile_event(serde_json::json!({"kind":"approval.response","requestId":"a1","conversationId":"chat-a"})));
        assert!(receiver.try_recv().is_ok()); // Update after snapshot is queued.
        drop(receiver);
        registry.notify("alice", approval); // Late duplicate cannot resurrect.
        let (_, pending) = registry.subscribe("alice").await;
        assert_eq!(pending, vec![clarify]);
        registry.notify("alice", protocol::mobile_event(serde_json::json!({"kind":"agent_gateway_event",
            "event":{"type":"event","event_type":"clarify.cancel","payload":{"request_id":"q1","conversation_id":"chat-b"}}})));
        assert!(registry.subscribe("alice").await.1.is_empty());
    }

    #[tokio::test]
    async fn pending_interaction_cache_is_bounded_and_expires() {
        let registry = MobileRegistry::default();
        for index in 0..200 {
            registry.notify("alice", protocol::mobile_event(serde_json::json!({"kind":"approval.request","requestId":format!("a{index}"),"timeout_ms":1})));
        }
        assert!(registry.subscribe("alice").await.1.len() <= MOBILE_EVENT_BUFFER);
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(registry.subscribe("alice").await.1.is_empty());
    }

    #[test]
    fn heartbeat_is_longer_than_handshake() {
        assert!(HEARTBEAT_INTERVAL > HANDSHAKE_TIMEOUT);
    }

    #[test]
    fn heartbeat_uses_mobile_ping_envelope() {
        let heartbeat = mobile_heartbeat();
        assert_eq!(heartbeat.version, PROTOCOL_VERSION);
        assert_eq!(heartbeat.message_type, protocol::MOBILE_PING);
        assert_eq!(heartbeat.request_id, None);
        assert_eq!(heartbeat.payload, serde_json::json!({}));
        assert_eq!(
            protocol::parse_mobile_envelope(&serde_json::to_string(&heartbeat).unwrap()).unwrap(),
            heartbeat
        );
    }

    #[test]
    fn mobile_heartbeat_interval_is_stable() {
        assert_eq!(HEARTBEAT_INTERVAL, Duration::from_secs(20));
    }
}

#[cfg(test)]
mod session_control_tests {
    use super::looks_like_slash_confirm;

    #[tokio::test]
    async fn interaction_waits_for_host_ack_and_host_error_remains_retryable() {
        use crate::agent_gateway::{
            protocol::{ApprovalDecision, GatewayMessage},
            AgentCommand,
        };
        use crate::conversation_routing_tests::{bind, memory_state};
        use tokio::sync::mpsc;
        let state = memory_state().await;
        let _ = bind(&state, "mac-chat", "mac").await.unwrap();
        let (tx, mut rx) = mpsc::channel(4);
        state
            .agent
            .register_connection(
                "interaction-test".into(),
                "u1".into(),
                "mac".into(),
                "macos".into(),
                tx,
            )
            .await;
        state.mobile.notify("u1", crate::agent_gateway::protocol::mobile_event(serde_json::json!({
            "kind":"approval.request", "conversationId":"mac-chat", "requestId":"approval-test", "action":"write",
        })));
        let message = GatewayMessage::ApprovalResolve {
            version: 1,
            event_id: "mobile-response".into(),
            seq: 0,
            session_id: "mac-chat".into(),
            request_id: "approval-test".into(),
            decision: ApprovalDecision::Once,
            reason: None,
        };
        for attempt in 0..2 {
            let task_state = state.clone();
            let control = message.clone();
            let task = tokio::spawn(async move {
                super::resolve_mobile_interaction(
                    &task_state,
                    "u1",
                    Some("mac"),
                    "mac-chat",
                    control,
                )
                .await
            });
            let AgentCommand::Send(frame) =
                tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
                    .await
                    .unwrap()
                    .unwrap()
            else {
                panic!("wrong command")
            };
            let serialized = serde_json::to_string(&frame).unwrap();
            assert!(crate::agent_gateway::protocol::parse_message(&serialized).is_ok());
            assert!(frame.event_metadata().unwrap().1 > 0); // Hermes rejects seq=0.
            assert!(!task.is_finished());
            assert!(state.mobile.has_pending("u1", "approval-test", "mac-chat"));
            assert!(super::resolve_mobile_interaction(
                &state,
                "u1",
                Some("mac"),
                "mac-chat",
                message.clone()
            )
            .await
            .is_err());
            if attempt == 0 {
                assert!(
                    state
                        .agent
                        .resolve_reply_for_device(
                            "mac",
                            GatewayMessage::Error {
                                version: 1,
                                code: "RESOLVER_FAILED".into(),
                                message: "try again".into(),
                                reply_to: Some("approval-test".into())
                            }
                        )
                        .await
                );
                assert!(task.await.unwrap().unwrap_err().contains("RESOLVER_FAILED"));
                assert!(state.mobile.has_pending("u1", "approval-test", "mac-chat"));
            } else {
                let ack = GatewayMessage::MessageAck {
                    version: 1,
                    message_id: "approval-test".into(),
                    status: "resolved".into(),
                };
                assert!(
                    !state
                        .agent
                        .resolve_reply_for_device("aozora", ack.clone())
                        .await
                );
                assert!(state.agent.resolve_reply_for_device("mac", ack).await);
                task.await.unwrap().unwrap();
                assert!(!state.mobile.has_pending("u1", "approval-test", "mac-chat"));
                assert!(state.mobile.subscribe("u1").await.1.is_empty());
            }
        }
    }

    #[tokio::test]
    async fn workspace_requires_owned_binding_and_rejects_wrong_host_reply() {
        use crate::agent_gateway::{protocol::GatewayMessage, AgentCommand};
        use crate::conversation_routing_tests::{bind, memory_state};
        use tokio::sync::mpsc;
        let state = memory_state().await;
        let request = serde_json::json!({"op":"capabilities"});
        for (user, chat) in [("u1", "legacy"), ("u1", "missing"), ("u2", "mac-chat")] {
            assert!(
                super::workspace_request(&state, user, chat, "mobile-1", request.clone())
                    .await
                    .is_err()
            );
        }
        let _ = bind(&state, "mac-chat", "mac").await.unwrap();
        let (tx, mut rx) = mpsc::channel(4);
        state
            .agent
            .register_connection(
                "workspace-test".into(),
                "u1".into(),
                "mac".into(),
                "macos".into(),
                tx,
            )
            .await;
        let task_state = state.clone();
        let task = tokio::spawn(async move {
            super::workspace_request(&task_state, "u1", "mac-chat", "mobile-1", request).await
        });
        let AgentCommand::Send(message) =
            tokio::time::timeout(std::time::Duration::from_secs(2), rx.recv())
                .await
                .unwrap()
                .unwrap()
        else {
            panic!("wrong command")
        };
        let GatewayMessage::WorkspaceRequest {
            request_id,
            conversation_id,
            ..
        } = *message
        else {
            panic!("wrong message")
        };
        let response = GatewayMessage::WorkspaceResponse {
            version: 1,
            request_id,
            conversation_id,
            payload: serde_json::json!({"ok":true,"data":{"workspaces":[]}}),
        };
        assert!(
            !state
                .agent
                .resolve_reply_for_device("aozora", response.clone())
                .await
        );
        assert!(state.agent.resolve_reply_for_device("mac", response).await);
        assert_eq!(
            task.await.unwrap().unwrap()["data"]["workspaces"],
            serde_json::json!([])
        );
        state.agent.remove_connection("workspace-test").await;
        assert!(super::workspace_request(
            &state,
            "u1",
            "mac-chat",
            "mobile-2",
            serde_json::json!({"op":"list"})
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn conversation_command_and_confirm_stay_on_bound_device() {
        use crate::agent_gateway::{protocol::GatewayMessage, AgentCommand};
        use crate::conversation_routing_tests::{bind, memory_state};
        use tokio::sync::mpsc;
        let state = memory_state().await;
        let _ = bind(&state, "mac-chat", "mac").await.unwrap();
        let (mac_tx, mut mac_rx) = mpsc::channel(4);
        let (ao_tx, mut ao_rx) = mpsc::channel(4);
        state
            .agent
            .register_connection(
                "cm".into(),
                "u1".into(),
                "mac".into(),
                "macos".into(),
                mac_tx,
            )
            .await;
        state
            .agent
            .register_connection(
                "ca".into(),
                "u1".into(),
                "aozora".into(),
                "linux".into(),
                ao_tx,
            )
            .await;
        let command_state = state.clone();
        let task = tokio::spawn(async move {
            super::run_session_command(&command_state, "u1", "mac-chat", "command-1", "/new").await
        });
        for (expected, content) in [
            ("/new", "Confirm /new approve cancel"),
            ("/approve", "Done"),
        ] {
            let command = tokio::time::timeout(std::time::Duration::from_secs(2), mac_rx.recv())
                .await
                .unwrap()
                .unwrap();
            let AgentCommand::Send(message) = command else {
                panic!("wrong command")
            };
            let GatewayMessage::MessageSend {
                message_id,
                conversation_id,
                content: sent,
                ..
            } = *message
            else {
                panic!("wrong command")
            };
            assert_eq!(sent, expected);
            assert!(ao_rx.try_recv().is_err());
            state
                .agent
                .resolve_reply(GatewayMessage::MessageReply {
                    version: 1,
                    message_id: format!("reply-{expected}"),
                    reply_to: message_id,
                    conversation_id,
                    content: content.into(),
                    attachments: vec![],
                })
                .await;
        }
        assert_eq!(task.await.unwrap().unwrap(), "Done");
        state.agent.remove_connection("cm").await;
        assert!(
            super::run_session_command(&state, "u1", "mac-chat", "command-offline", "/status")
                .await
                .is_err()
        );
        assert!(ao_rx.try_recv().is_err());
    }

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
