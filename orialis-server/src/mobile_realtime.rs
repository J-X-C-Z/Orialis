use axum::{
    extract::ws::{Message, WebSocket, WebSocketUpgrade},
    extract::State,
    http::HeaderMap,
    response::IntoResponse,
};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{broadcast, Mutex};

use crate::{authenticated_user, AppState};

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

#[derive(Debug, Deserialize, Serialize)]
struct MobileEnvelope {
    version: u32,
    #[serde(rename = "type")]
    message_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<String>,
    payload: Value,
}

pub async fn upgrade(
    ws: WebSocketUpgrade,
    headers: HeaderMap,
    State(state): State<Arc<AppState>>,
) -> impl IntoResponse {
    let Ok(user_id) = authenticated_user(&headers, &state.pool).await else {
        return (axum::http::StatusCode::UNAUTHORIZED, "valid session required").into_response();
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
                    if handle_text(&mut socket, text.as_str()).await.is_err() { break; }
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

async fn handle_text(socket: &mut WebSocket, text: &str) -> Result<(), ()> {
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
        "pong" | "event" | "message" | "sync.change_hint" => Ok(()),
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
