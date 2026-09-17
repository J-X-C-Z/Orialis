//! Axum WebSocket endpoint for the Orialis ↔ Hermes Agent Gateway MVP.

use super::{protocol, AgentCommand, EventDisposition, RegistryError};
use crate::{AppError, AppState};
use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        State,
    },
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Duration as ChronoDuration, Utc};
use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::Value;
use std::{sync::Arc, time::Duration};
use tokio::sync::mpsc;
use uuid::Uuid;

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);
const DEBUG_REPLY_TIMEOUT: Duration = Duration::from_secs(60);
const MOBILE_HEARTBEAT: Duration = Duration::from_secs(20);

fn mobile_heartbeat() -> protocol::MobileEnvelope {
    protocol::mobile_envelope(protocol::MOBILE_PING, None, serde_json::json!({}))
}

pub async fn upgrade(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    State(state): State<Arc<AppState>>,
) -> Response {
    if let Err(status) = validate_agent_token(
        &headers,
        state.agent_device_token.as_deref(),
        &state.metadata.environment,
    ) {
        let message = if status == StatusCode::SERVICE_UNAVAILABLE {
            "Agent authentication is not configured on the server"
        } else {
            "valid Agent device token required"
        };
        return (
            status,
            Json(serde_json::json!({
                "error": { "code": "unauthorized", "message": message }
            })),
        )
            .into_response();
    }
    ws.on_upgrade(move |socket| handle_socket(state, socket))
        .into_response()
}

fn validate_agent_token(
    headers: &HeaderMap,
    expected_token: Option<&str>,
    environment: &str,
) -> Result<(), StatusCode> {
    let Some(expected_token) = expected_token else {
        return if environment == "development" {
            Ok(())
        } else {
            Err(StatusCode::SERVICE_UNAVAILABLE)
        };
    };
    let valid = headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split_once(' '))
        .is_some_and(|(scheme, token)| {
            scheme.eq_ignore_ascii_case("bearer") && !token.is_empty() && token == expected_token
        });
    if valid {
        Ok(())
    } else {
        Err(StatusCode::UNAUTHORIZED)
    }
}

/// Minimal WebSocket channel for ordinary Orialis mobile clients.
///
/// This is deliberately independent from the Hermes registry: it owns the
/// connection lifecycle and protocol-level heartbeat only. Domain events can
/// be sent later through `send_mobile`, once a broadcaster is wired in.
pub async fn mobile_upgrade(ws: WebSocketUpgrade) -> impl IntoResponse {
    ws.on_upgrade(handle_mobile_socket)
}

async fn handle_mobile_socket(mut socket: WebSocket) {
    let hello = match tokio::time::timeout(HANDSHAKE_TIMEOUT, socket.next()).await {
        Ok(Some(Ok(Message::Text(text)))) => protocol::parse_mobile_envelope(text.as_str()),
        Ok(Some(Ok(_))) => Err(protocol::ProtocolError::InvalidMessage),
        Ok(Some(Err(_))) | Ok(None) | Err(_) => return,
    };
    let hello = match hello {
        Ok(envelope) if envelope.message_type == protocol::MOBILE_HELLO => envelope,
        Ok(_) => {
            let _ = send_mobile(
                &mut socket,
                protocol::mobile_error("INVALID_MESSAGE", "first message must be hello", None),
            )
            .await;
            return;
        }
        Err(error) => {
            let _ = send_mobile(
                &mut socket,
                protocol::mobile_error("INVALID_MESSAGE", &error.to_string(), None),
            )
            .await;
            return;
        }
    };
    let connection_id = Uuid::now_v7().to_string();
    let _ = send_mobile(
        &mut socket,
        protocol::mobile_envelope(
            protocol::MOBILE_HELLO_ACK,
            hello.request_id.clone(),
            serde_json::json!({ "connection_id": connection_id }),
        ),
    )
    .await;
    tracing::info!(%connection_id, "orialis mobile WebSocket connected");

    let mut heartbeat = tokio::time::interval(MOBILE_HEARTBEAT);
    heartbeat.tick().await;
    loop {
        tokio::select! {
            incoming = socket.next() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    if handle_mobile_text(&mut socket, text.as_str()).await.is_err() { break; }
                }
                Some(Ok(Message::Ping(payload))) => {
                    if socket.send(Message::Pong(payload)).await.is_err() { break; }
                }
                Some(Ok(Message::Close(_))) | None => break,
                Some(Ok(_)) => {}
                Some(Err(_)) => break,
            },
            _ = heartbeat.tick() => {
                if send_mobile(&mut socket, mobile_heartbeat()).await.is_err() { break; }
            }
        }
    }
    tracing::info!(%connection_id, "orialis mobile WebSocket disconnected");
}

async fn handle_mobile_text(socket: &mut WebSocket, text: &str) -> Result<(), ()> {
    let envelope = match protocol::parse_mobile_envelope(text) {
        Ok(envelope) => envelope,
        Err(error) => {
            return send_mobile(
                socket,
                protocol::mobile_error("INVALID_MESSAGE", &error.to_string(), None),
            )
            .await
        }
    };
    match envelope.message_type.as_str() {
        protocol::MOBILE_PING => {
            send_mobile(
                socket,
                protocol::mobile_envelope(
                    protocol::MOBILE_PONG,
                    envelope.request_id,
                    Value::Object(Default::default()),
                ),
            )
            .await
        }
        protocol::MOBILE_PONG
        | protocol::MOBILE_EVENT
        | protocol::MOBILE_MESSAGE
        | protocol::MOBILE_SYNC_CHANGE_HINT => Ok(()),
        protocol::MOBILE_HELLO => {
            send_mobile(
                socket,
                protocol::mobile_error(
                    "INVALID_MESSAGE",
                    "hello is only valid as the first message",
                    envelope.request_id,
                ),
            )
            .await
        }
        _ => {
            send_mobile(
                socket,
                protocol::mobile_error(
                    "INVALID_MESSAGE",
                    "message type is not valid from the mobile client",
                    envelope.request_id,
                ),
            )
            .await
        }
    }
}

async fn send_mobile(socket: &mut WebSocket, message: protocol::MobileEnvelope) -> Result<(), ()> {
    let payload = serde_json::to_string(&message).map_err(|_| ())?;
    socket
        .send(Message::Text(payload.into()))
        .await
        .map_err(|_| ())
}

#[cfg(test)]
mod auth_tests {
    use super::*;

    #[test]
    fn development_allows_connection_without_configured_token() {
        assert_eq!(
            validate_agent_token(&HeaderMap::new(), None, "development"),
            Ok(())
        );
    }

    #[test]
    fn production_requires_server_token_configuration() {
        assert_eq!(
            validate_agent_token(&HeaderMap::new(), None, "production"),
            Err(StatusCode::SERVICE_UNAVAILABLE)
        );
    }

    #[test]
    fn bearer_token_is_required_and_not_logged_or_returned() {
        let mut headers = HeaderMap::new();
        headers.insert("authorization", "Bearer server-secret".parse().unwrap());
        assert_eq!(
            validate_agent_token(&headers, Some("server-secret"), "production"),
            Ok(())
        );
        headers.insert("authorization", "Bearer wrong-secret".parse().unwrap());
        assert_eq!(
            validate_agent_token(&headers, Some("server-secret"), "production"),
            Err(StatusCode::UNAUTHORIZED)
        );
    }
}

#[cfg(test)]
mod mobile_tests {
    use super::*;

    #[test]
    fn heartbeat_is_longer_than_handshake() {
        assert!(MOBILE_HEARTBEAT > HANDSHAKE_TIMEOUT);
    }

    #[test]
    fn heartbeat_uses_mobile_ping_envelope() {
        let heartbeat = mobile_heartbeat();
        assert_eq!(heartbeat.version, protocol::PROTOCOL_VERSION);
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
        assert_eq!(MOBILE_HEARTBEAT, Duration::from_secs(20));
    }
}

async fn handle_socket(state: Arc<AppState>, mut socket: WebSocket) {
    let first_message = match tokio::time::timeout(HANDSHAKE_TIMEOUT, socket.next()).await {
        Ok(Some(Ok(Message::Text(text)))) => text.to_string(),
        Ok(Some(Ok(_))) => {
            let _ = send_error(
                &mut socket,
                "INVALID_MESSAGE",
                "first WebSocket message must be hello",
            )
            .await;
            return;
        }
        Ok(Some(Err(error))) => {
            tracing::warn!(%error, "Orialis Agent WebSocket failed during hello");
            return;
        }
        Ok(None) | Err(_) => {
            tracing::warn!("Orialis Agent WebSocket hello timed out or closed");
            return;
        }
    };

    let hello = match protocol::parse_message(&first_message) {
        Ok(protocol::GatewayMessage::Hello {
            device_id,
            client,
            plugin_version,
            platform,
            ..
        }) => (device_id, client, plugin_version, platform),
        Ok(_) => {
            let _ = send_error(
                &mut socket,
                "INVALID_MESSAGE",
                "first message must be hello",
            )
            .await;
            return;
        }
        Err(error) => {
            let _ = send_protocol_error(&mut socket, &error).await;
            return;
        }
    };

    let user_id = match resolve_agent_owner(&state).await {
        Ok(Some(user_id)) => user_id,
        Ok(None) => {
            let _ = send_error(
                &mut socket,
                "AGENT_OWNER_REQUIRED",
                "configure ORIALIS_AGENT_USER_ID when the server has multiple users",
            )
            .await;
            return;
        }
        Err(error) => {
            tracing::error!(%error, "could not resolve the Orialis Agent owner");
            let _ = send_error(
                &mut socket,
                "AGENT_OWNER_INVALID",
                "the configured Orialis Agent owner does not exist",
            )
            .await;
            return;
        }
    };
    if let Err(error) =
        register_agent_device(&state, &user_id, &hello.0, &hello.1, &hello.2, &hello.3).await
    {
        tracing::warn!(?error, device_id = %hello.0, "could not register Orialis Agent device");
        let _ = send_error(
            &mut socket,
            "AGENT_DEVICE_REJECTED",
            "agent device is not available",
        )
        .await;
        return;
    }

    let (command_tx, mut command_rx) = mpsc::channel(32);
    let connection_id = Uuid::now_v7().to_string();
    state
        .agent
        .register_connection(
            connection_id.clone(),
            user_id.clone(),
            hello.0.clone(),
            hello.3.clone(),
            command_tx,
        )
        .await;
    if send_message(
        &mut socket,
        &protocol::GatewayMessage::HelloAck {
            version: protocol::PROTOCOL_VERSION,
        },
    )
    .await
    .is_err()
    {
        state.agent.remove_connection(&connection_id).await;
        return;
    }
    tracing::info!(device_id = %hello.0, platform = %hello.3, "orialis-hermes-plugin connected");

    let mut maintenance = tokio::time::interval(Duration::from_secs(1));
    maintenance.tick().await;
    loop {
        tokio::select! {
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => handle_text(&state, &mut socket, &user_id, &hello.0, text.to_string()).await,
                    Some(Ok(Message::Ping(payload))) => {
                        if socket.send(Message::Pong(payload)).await.is_err() { break; }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        tracing::warn!(%error, "Orialis Agent WebSocket connection failed");
                        break;
                    }
                }
            }
            command = command_rx.recv() => {
                match command {
                    Some(AgentCommand::Send(message)) => {
                        if send_message(&mut socket, &message).await.is_err() { break; }
                    }
                    Some(AgentCommand::Close) | None => break,
                }
            }
            _ = maintenance.tick() => {
                for (request_id, session_id) in state.agent.expire_approvals(&hello.0).await {
                    let timeout = protocol::GatewayMessage::ApprovalResolve {
                        version: protocol::PROTOCOL_VERSION,
                        event_id: format!("approval-timeout-{}", Uuid::now_v7()),
                        seq: 0,
                        session_id,
                        request_id,
                        decision: protocol::ApprovalDecision::Timeout,
                        reason: Some("approval request timed out".into()),
                    };
                    if let Some(timeout) = state.agent.record_server_event(&hello.0, timeout).await {
                        if send_message(&mut socket, &timeout).await.is_err() { break; }
                    }
                }
            }
        }
    }

    state.agent.remove_connection(&connection_id).await;
    mark_agent_device_seen(&state, &user_id, &hello.0).await;
    state.mobile.notify(
        &user_id,
        protocol::mobile_event(serde_json::json!({
            "kind": "agent_devices_changed",
            "reason": "disconnected",
            "deviceId": hello.0,
        })),
    );
    tracing::info!(device_id = %hello.0, platform = %hello.3, "Orialis Agent WebSocket connection closed");
}

async fn resolve_agent_owner(state: &AppState) -> Result<Option<String>, sqlx::Error> {
    if let Some(user_id) = state.agent_user_id.as_deref() {
        let exists = sqlx::query_scalar::<_, i64>("SELECT EXISTS(SELECT 1 FROM users WHERE id=?)")
            .bind(user_id)
            .fetch_one(&state.pool)
            .await?;
        return Ok((exists != 0).then(|| user_id.to_owned()));
    }
    let users =
        sqlx::query_scalar::<_, String>("SELECT id FROM users ORDER BY created_at,id LIMIT 2")
            .fetch_all(&state.pool)
            .await?;
    Ok((users.len() == 1).then(|| users[0].clone()))
}

async fn register_agent_device(
    state: &AppState,
    user_id: &str,
    device_id: &str,
    client: &str,
    plugin_version: &str,
    platform: &str,
) -> Result<(), AppError> {
    if let Some(existing_user_id) =
        sqlx::query_scalar::<_, String>("SELECT user_id FROM agent_devices WHERE device_id=?")
            .bind(device_id)
            .fetch_optional(&state.pool)
            .await?
    {
        if existing_user_id != user_id {
            return Err(AppError::Unauthorized);
        }
    }
    let timestamp = chrono::Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO agent_devices
            (device_id,user_id,client,plugin_version,platform,last_seen_at,created_at,updated_at)
         VALUES (?,?,?,?,?,?,?,?)
         ON CONFLICT(device_id) DO UPDATE SET
            client=excluded.client, plugin_version=excluded.plugin_version,
            platform=excluded.platform, last_seen_at=excluded.last_seen_at,
            updated_at=excluded.updated_at, version=agent_devices.version+1",
    )
    .bind(device_id)
    .bind(user_id)
    .bind(client)
    .bind(plugin_version)
    .bind(platform)
    .bind(&timestamp)
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&state.pool)
    .await?;
    sqlx::query(
        "INSERT OR IGNORE INTO agent_preferences
            (user_id,active_device_id,created_at,updated_at)
         VALUES (?,?,?,?)",
    )
    .bind(user_id)
    .bind(device_id)
    .bind(&timestamp)
    .bind(&timestamp)
    .execute(&state.pool)
    .await?;
    state.mobile.notify(
        user_id,
        protocol::mobile_event(serde_json::json!({
            "kind": "agent_devices_changed",
            "reason": "connected",
            "deviceId": device_id,
        })),
    );
    Ok(())
}

async fn mark_agent_device_seen(state: &AppState, user_id: &str, device_id: &str) {
    if let Err(error) = sqlx::query(
        "UPDATE agent_devices SET last_seen_at=?,updated_at=? WHERE user_id=? AND device_id=?",
    )
    .bind(chrono::Utc::now().to_rfc3339())
    .bind(chrono::Utc::now().to_rfc3339())
    .bind(user_id)
    .bind(device_id)
    .execute(&state.pool)
    .await
    {
        tracing::warn!(%error, %device_id, "could not update Orialis Agent device heartbeat");
    }
}

async fn handle_text(
    state: &Arc<AppState>,
    socket: &mut WebSocket,
    user_id: &str,
    device_id: &str,
    text: String,
) {
    match protocol::parse_message(&text) {
        Ok(protocol::GatewayMessage::Ping { .. }) => {
            let _ = send_message(
                socket,
                &protocol::GatewayMessage::Pong {
                    version: protocol::PROTOCOL_VERSION,
                },
            )
            .await;
        }
        Ok(message @ protocol::GatewayMessage::MessageReply { .. }) => {
            if let Some(message_id) = message.message_id() {
                let _ = send_message(socket, &protocol::ack(message_id)).await;
            }
            state.agent.resolve_reply(message).await
        }
        Ok(message @ protocol::GatewayMessage::Error { .. }) => {
            // Unsolicited agent errors are diagnostic events, not replies to a
            // pending request. Only route correlated errors through the reply
            // resolver; otherwise they create misleading `without reply_to`
            // warnings and can interfere with delivery diagnostics.
            if message.reply_to().is_some() {
                state.agent.resolve_reply(message).await
            } else {
                tracing::warn!(device_id = %device_id, "received unsolicited Orialis Agent error");
            }
        }
        Ok(protocol::GatewayMessage::MessageAck {
            message_id, status, ..
        }) => {
            tracing::debug!(%message_id, %status, "Orialis Hermes plugin acknowledged message");
        }
        Ok(protocol::GatewayMessage::CapabilitiesHello { resume_from, .. }) => {
            let resume_from = resume_from.unwrap_or(0);
            let acknowledgement = state.agent.capabilities_ack(device_id, resume_from).await;
            if send_message(socket, &acknowledgement).await.is_err() {
                return;
            }
            for message in state.agent.replay_after(device_id, resume_from).await {
                if send_message(socket, &message).await.is_err() {
                    return;
                }
            }
        }
        Ok(message) if message.event_metadata().is_some() => {
            let Some((event_id, seq, _)) = message.event_metadata() else {
                return;
            };
            let disposition = state.agent.accept_event(device_id, message.clone()).await;
            match disposition {
                EventDisposition::Accepted => {
                    let _ = send_message(
                        socket,
                        &protocol::agent_ack(event_id, seq, "received", None),
                    )
                    .await;
                    state.mobile.notify(
                        user_id,
                        protocol::mobile_event(serde_json::json!({
                            "kind": "agent_gateway_event",
                            "event": serde_json::to_value(message).unwrap_or(Value::Null),
                        })),
                    );
                }
                EventDisposition::Duplicate => {
                    let _ = send_message(
                        socket,
                        &protocol::agent_ack(event_id, seq, "duplicate", None),
                    )
                    .await;
                }
                EventDisposition::Gap { expected_seq } => {
                    let _ = send_message(
                        socket,
                        &protocol::agent_ack(event_id, seq, "gap", Some(expected_seq)),
                    )
                    .await;
                }
                EventDisposition::UnknownApproval => {
                    let _ =
                        send_message(socket, &protocol::agent_ack(event_id, seq, "unknown", None))
                            .await;
                    let _ = send_error(
                        socket,
                        "UNKNOWN_APPROVAL",
                        "approval request is not pending",
                    )
                    .await;
                }
            }
        }
        Ok(protocol::GatewayMessage::AgentAck { .. })
        | Ok(protocol::GatewayMessage::CapabilitiesAck { .. }) => {}
        Ok(_) => {
            let _ = send_error(
                socket,
                "INVALID_MESSAGE",
                "message type is not valid from the plugin",
            )
            .await;
        }
        Err(error) => {
            let _ = send_protocol_error(socket, &error).await;
        }
    }
}

async fn send_message(
    socket: &mut WebSocket,
    message: &protocol::GatewayMessage,
) -> Result<(), ()> {
    let payload = serde_json::to_string(message).map_err(|_| ())?;
    socket
        .send(Message::Text(payload.into()))
        .await
        .map_err(|_| ())
}

async fn send_protocol_error(
    socket: &mut WebSocket,
    error: &protocol::ProtocolError,
) -> Result<(), ()> {
    send_message(socket, &protocol::error_for(error, None)).await
}

async fn send_error(socket: &mut WebSocket, code: &str, message: &str) -> Result<(), ()> {
    send_message(
        socket,
        &protocol::GatewayMessage::Error {
            version: protocol::PROTOCOL_VERSION,
            code: code.to_owned(),
            message: message.to_owned(),
            reply_to: None,
        },
    )
    .await
}

#[derive(Debug, Deserialize)]
pub struct DebugMessageInput {
    pub conversation_id: String,
    pub content: String,
    pub message_id: Option<String>,
}

pub async fn debug_message(
    State(state): State<Arc<AppState>>,
    Json(input): Json<DebugMessageInput>,
) -> Result<Json<protocol::GatewayMessage>, AppError> {
    if state.metadata.environment != "development" {
        return Err(AppError::NotFound);
    }
    if input.conversation_id.trim().is_empty() {
        return Err(AppError::BadRequest("conversation_id is required".into()));
    }
    if input.content.trim().is_empty() {
        return Err(AppError::BadRequest("content is required".into()));
    }
    let message = protocol::GatewayMessage::MessageSend {
        version: protocol::PROTOCOL_VERSION,
        message_id: input
            .message_id
            .unwrap_or_else(|| format!("msg_{}", Uuid::now_v7())),
        conversation_id: input.conversation_id,
        content: input.content,
        attachments: vec![],
    };
    let receiver = state
        .agent
        .send_request(message)
        .await
        .map_err(|error| match error {
            RegistryError::DuplicateMessage => AppError::Conflict(error.to_string()),
            RegistryError::NoConnection | RegistryError::ConnectionClosed => {
                AppError::ServiceUnavailable(error.to_string())
            }
        })?;
    let reply = tokio::time::timeout(DEBUG_REPLY_TIMEOUT, receiver)
        .await
        .map_err(|_| AppError::ServiceUnavailable("timed out waiting for Hermes reply".into()))?
        .map_err(|_| {
            AppError::ServiceUnavailable("plugin connection closed before replying".into())
        })?;
    Ok(Json(reply))
}

/// Deliver a persisted mobile message to the connected Hermes plugin and save
/// the first valid assistant reply back to the same Orialis conversation.
///
/// This runs in the background after the HTTP request has committed the user
/// message, so a temporarily offline Hermes plugin never loses the mobile
/// message or makes the mobile request wait for the agent runtime.
pub(crate) async fn dispatch_message(
    state: Arc<AppState>,
    user_id: String,
    conversation_id: String,
    message_id: String,
    content: String,
    attachments: Vec<protocol::GatewayAttachment>,
) {
    let Some(attempts) = claim_delivery(&state, &message_id).await else {
        return;
    };
    let request = protocol::GatewayMessage::MessageSend {
        version: protocol::PROTOCOL_VERSION,
        message_id: message_id.clone(),
        conversation_id: conversation_id.clone(),
        content,
        attachments,
    };
    let active_device_id = match sqlx::query_scalar::<_, Option<String>>(
        "SELECT active_device_id FROM agent_preferences WHERE user_id=?",
    )
    .bind(&user_id)
    .fetch_optional(&state.pool)
    .await
    {
        Ok(active_device_id) => active_device_id.flatten(),
        Err(error) => {
            tracing::warn!(%error, %message_id, "could not read active Orialis Agent device");
            return;
        }
    };
    // A mobile POST can race the final handshake bookkeeping on a freshly
    // connected Agent. Give that connection a short grace window before
    // rescheduling the durable delivery for a much longer retry interval.
    let mut receiver = None;
    let mut last_error = None;
    for attempt in 0..4 {
        match state
            .agent
            .send_request_for_user(&user_id, active_device_id.as_deref(), request.clone())
            .await
        {
            Ok(value) => {
                receiver = Some(value);
                break;
            }
            Err(error) => {
                last_error = Some(error);
                if attempt < 3 {
                    tokio::time::sleep(Duration::from_millis(50 * (attempt + 1))).await;
                }
            }
        }
    }
    let Some(receiver) = receiver else {
        let error = last_error.unwrap_or(RegistryError::ConnectionClosed);
        tracing::warn!(%error, %message_id, "could not dispatch mobile message to Hermes");
        fail_delivery(&state, &message_id, attempts, error.to_string()).await;
        return;
    };
    let reply = match tokio::time::timeout(DEBUG_REPLY_TIMEOUT, receiver).await {
        Ok(Ok(reply)) => reply,
        Ok(Err(_)) => {
            tracing::warn!(%message_id, "Hermes disconnected before replying to mobile message");
            state.agent.cancel_request(&message_id).await;
            fail_delivery(
                &state,
                &message_id,
                attempts,
                "agent connection closed".into(),
            )
            .await;
            return;
        }
        Err(_) => {
            tracing::warn!(%message_id, "Hermes reply timed out for mobile message");
            state.agent.cancel_request(&message_id).await;
            fail_delivery(
                &state,
                &message_id,
                attempts,
                "agent reply timed out".into(),
            )
            .await;
            return;
        }
    };
    let protocol::GatewayMessage::MessageReply {
        message_id: reply_id,
        reply_to,
        conversation_id: reply_conversation_id,
        content,
        attachments,
        ..
    } = reply
    else {
        tracing::warn!(%message_id, "Hermes returned a non-reply response for mobile message");
        fail_delivery(
            &state,
            &message_id,
            attempts,
            "agent returned a non-reply response".into(),
        )
        .await;
        return;
    };
    if reply_to != message_id || reply_conversation_id != conversation_id {
        tracing::warn!(
            %message_id,
            %reply_to,
            reply_conversation_id = %reply_conversation_id,
            "Hermes reply did not match mobile message"
        );
        fail_delivery(
            &state,
            &message_id,
            attempts,
            "agent reply did not match request".into(),
        )
        .await;
        return;
    }

    let attachments_json =
        match canonical_reply_attachments(&state, &user_id, &conversation_id, &attachments).await {
            Ok(value) => value,
            Err(error) => {
                tracing::warn!(%message_id, %error, "Hermes reply contained invalid attachments");
                fail_delivery(
                    &state,
                    &message_id,
                    attempts,
                    "agent reply contained invalid attachments".into(),
                )
                .await;
                return;
            }
        };
    let mut transaction = match state.pool.begin().await {
        Ok(transaction) => transaction,
        Err(error) => {
            tracing::error!(%error, %message_id, "failed to start reply transaction");
            fail_delivery(
                &state,
                &message_id,
                attempts,
                "could not start reply transaction".into(),
            )
            .await;
            return;
        }
    };
    let result = sqlx::query(
        "INSERT INTO messages (id,user_id,conversation_id,role,content,attachments_json)
         VALUES (?,?,?,'assistant',?,?) ON CONFLICT(id) DO NOTHING",
    )
    .bind(&reply_id)
    .bind(&user_id)
    .bind(&conversation_id)
    .bind(&content)
    .bind(&attachments_json)
    .execute(&mut *transaction)
    .await;
    let Ok(result) = result else {
        tracing::error!(%message_id, "failed to persist Hermes reply");
        fail_delivery(
            &state,
            &message_id,
            attempts,
            "failed to persist agent reply".into(),
        )
        .await;
        return;
    };
    let Ok((created_at, version)) = sqlx::query_as::<_, (String, i64)>(
        "SELECT created_at,version FROM messages WHERE id=? AND user_id=?",
    )
    .bind(&reply_id)
    .bind(&user_id)
    .fetch_one(&mut *transaction)
    .await
    else {
        tracing::error!(%reply_id, "failed to read persisted Hermes reply");
        fail_delivery(
            &state,
            &message_id,
            attempts,
            "failed to read persisted agent reply".into(),
        )
        .await;
        return;
    };
    if let Err(error) = sqlx::query("DELETE FROM agent_delivery_queue WHERE message_id=?")
        .bind(&message_id)
        .execute(&mut *transaction)
        .await
    {
        tracing::error!(%error, %message_id, "failed to remove delivered agent message");
        fail_delivery(
            &state,
            &message_id,
            attempts,
            "failed to finalize agent delivery".into(),
        )
        .await;
        return;
    }
    if let Err(error) = transaction.commit().await {
        tracing::error!(%error, %message_id, "failed to commit agent delivery");
        fail_delivery(
            &state,
            &message_id,
            attempts,
            "failed to commit agent delivery".into(),
        )
        .await;
        return;
    }
    state.mobile.notify(
        &user_id,
        protocol::mobile_message(serde_json::json!({
            "id": reply_id,
            "conversationId": conversation_id,
            "role": "assistant",
            "content": content,
            "attachments": serde_json::from_str::<Value>(&attachments_json).unwrap_or_default(),
            "createdAt": created_at,
            "version": version,
        })),
    );
    tracing::info!(%message_id, %reply_id, "persisted Hermes reply for mobile conversation");
}

async fn claim_delivery(state: &AppState, message_id: &str) -> Option<i64> {
    let current = Utc::now();
    let now = current.to_rfc3339();
    let result = sqlx::query(
        "UPDATE agent_delivery_queue
         SET attempts=attempts+1,next_attempt_at=?,updated_at=?
         WHERE message_id=? AND next_attempt_at<=?",
    )
    .bind((current + ChronoDuration::minutes(2)).to_rfc3339())
    .bind(&now)
    .bind(message_id)
    .bind(&now)
    .execute(&state.pool)
    .await
    .ok()?;
    if result.rows_affected() != 1 {
        return None;
    }
    sqlx::query_scalar("SELECT attempts FROM agent_delivery_queue WHERE message_id=?")
        .bind(message_id)
        .fetch_optional(&state.pool)
        .await
        .ok()
        .flatten()
}

async fn fail_delivery(state: &AppState, message_id: &str, attempts: i64, error: String) {
    let delay = 2_i64.pow(attempts.clamp(0, 8) as u32).min(300);
    if let Err(database_error) = sqlx::query(
        "UPDATE agent_delivery_queue SET next_attempt_at=?,last_error=?,updated_at=?
         WHERE message_id=?",
    )
    .bind((Utc::now() + ChronoDuration::seconds(delay)).to_rfc3339())
    .bind(error)
    .bind(Utc::now().to_rfc3339())
    .bind(message_id)
    .execute(&state.pool)
    .await
    {
        tracing::error!(%database_error, %message_id, "failed to reschedule agent delivery");
    }
}

pub(crate) async fn dispatch_due_messages(state: Arc<AppState>) {
    let rows = match sqlx::query_as::<_, (String, String, String, String, String)>(
        "SELECT q.user_id,q.conversation_id,q.message_id,m.content,m.attachments_json
         FROM agent_delivery_queue q JOIN messages m ON m.id=q.message_id
         WHERE q.next_attempt_at<=? ORDER BY q.created_at,q.message_id LIMIT 8",
    )
    .bind(Utc::now().to_rfc3339())
    .fetch_all(&state.pool)
    .await
    {
        Ok(rows) => rows,
        Err(error) => {
            tracing::warn!(%error, "could not read pending agent deliveries");
            return;
        }
    };
    for (user_id, conversation_id, message_id, content, attachments_json) in rows {
        let attachments = serde_json::from_str::<Vec<crate::Attachment>>(&attachments_json)
            .unwrap_or_default()
            .into_iter()
            .map(|attachment| protocol::GatewayAttachment {
                id: attachment.id,
                name: attachment.name,
                mime_type: attachment.mime_type,
                size: attachment.size,
                download_url: attachment.download_url,
            })
            .collect();
        dispatch_message(
            state.clone(),
            user_id,
            conversation_id,
            message_id,
            content,
            attachments,
        )
        .await;
    }
}

async fn canonical_reply_attachments(
    state: &AppState,
    user_id: &str,
    conversation_id: &str,
    attachments: &[protocol::GatewayAttachment],
) -> Result<String, sqlx::Error> {
    let mut canonical = Vec::with_capacity(attachments.len());
    for attachment in attachments {
        let row = sqlx::query_as::<_, (String, String, i64, String)>(
            "SELECT original_name,mime_type,size_bytes,conversation_id
             FROM attachments WHERE id=? AND user_id=?",
        )
        .bind(&attachment.id)
        .bind(user_id)
        .fetch_optional(&state.pool)
        .await?
        .ok_or_else(|| sqlx::Error::RowNotFound)?;
        if row.3 != conversation_id {
            return Err(sqlx::Error::RowNotFound);
        }
        canonical.push(serde_json::json!({
            "id": attachment.id,
            "name": row.0,
            "mimeType": row.1,
            "size": row.2,
            "downloadUrl": format!("{}/api/v1/attachments/{}/download", state.public_url.trim_end_matches('/'), attachment.id),
        }));
    }
    serde_json::to_string(&canonical).map_err(|error| sqlx::Error::Protocol(error.to_string()))
}
