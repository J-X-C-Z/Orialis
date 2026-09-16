//! Axum WebSocket endpoint for the Orialis ↔ Hermes Agent Gateway MVP.

use super::{protocol, AgentCommand, RegistryError};
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

    loop {
        tokio::select! {
            incoming = socket.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => handle_text(&state, &mut socket, text.to_string()).await,
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

async fn handle_text(state: &Arc<AppState>, socket: &mut WebSocket, text: String) {
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
            state.agent.resolve_reply(message).await
        }
        Ok(protocol::GatewayMessage::MessageAck {
            message_id, status, ..
        }) => {
            tracing::debug!(%message_id, %status, "Orialis Hermes plugin acknowledged message");
        }
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
) {
    let request = protocol::GatewayMessage::MessageSend {
        version: protocol::PROTOCOL_VERSION,
        message_id: message_id.clone(),
        conversation_id: conversation_id.clone(),
        content,
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
    let receiver = match state
        .agent
        .send_request_for_user(&user_id, active_device_id.as_deref(), request)
        .await
    {
        Ok(receiver) => receiver,
        Err(error) => {
            tracing::warn!(%error, %message_id, "could not dispatch mobile message to Hermes");
            return;
        }
    };
    let reply = match tokio::time::timeout(DEBUG_REPLY_TIMEOUT, receiver).await {
        Ok(Ok(reply)) => reply,
        Ok(Err(_)) => {
            tracing::warn!(%message_id, "Hermes disconnected before replying to mobile message");
            return;
        }
        Err(_) => {
            tracing::warn!(%message_id, "Hermes reply timed out for mobile message");
            return;
        }
    };
    let protocol::GatewayMessage::MessageReply {
        message_id: reply_id,
        reply_to,
        conversation_id: reply_conversation_id,
        content,
        ..
    } = reply
    else {
        tracing::warn!(%message_id, "Hermes returned a non-reply response for mobile message");
        return;
    };
    if reply_to != message_id || reply_conversation_id != conversation_id {
        tracing::warn!(
            %message_id,
            %reply_to,
            reply_conversation_id = %reply_conversation_id,
            "Hermes reply did not match mobile message"
        );
        return;
    }

    let result = sqlx::query(
        "INSERT INTO messages (id,user_id,conversation_id,role,content)
         VALUES (?,?,?,'assistant',?) ON CONFLICT(id) DO NOTHING",
    )
    .bind(&reply_id)
    .bind(&user_id)
    .bind(&conversation_id)
    .bind(&content)
    .execute(&state.pool)
    .await;
    let Ok(result) = result else {
        tracing::error!(%message_id, "failed to persist Hermes reply");
        return;
    };
    if result.rows_affected() == 0 {
        return;
    }
    let Ok((created_at, version)) = sqlx::query_as::<_, (String, i64)>(
        "SELECT created_at,version FROM messages WHERE id=? AND user_id=?",
    )
    .bind(&reply_id)
    .bind(&user_id)
    .fetch_one(&state.pool)
    .await
    else {
        tracing::error!(%reply_id, "failed to read persisted Hermes reply");
        return;
    };
    state.mobile.notify(
        &user_id,
        protocol::mobile_message(serde_json::json!({
            "id": reply_id,
            "conversationId": conversation_id,
            "role": "assistant",
            "content": content,
            "createdAt": created_at,
            "version": version,
        })),
    );
    tracing::info!(%message_id, %reply_id, "persisted Hermes reply for mobile conversation");
}
