//! The Agent Track boundary between Orialis Server and a Hermes platform plugin.

pub mod protocol;
pub mod ws;

use protocol::GatewayMessage;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fmt,
};
use tokio::sync::{mpsc, oneshot, Mutex};

const COMPLETED_REQUEST_CACHE: usize = 4096;

#[derive(Debug)]
pub(crate) enum AgentCommand {
    Send(GatewayMessage),
    Close,
}

#[derive(Debug)]
struct AgentConnection {
    id: String,
    user_id: String,
    device_id: String,
    platform: String,
    command_tx: mpsc::Sender<AgentCommand>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct OnlineAgent {
    pub device_id: String,
    pub platform: String,
}

struct PendingRequest {
    reply_tx: oneshot::Sender<GatewayMessage>,
    device_id: String,
}

#[derive(Default)]
struct RegistryState {
    connections: HashMap<String, AgentConnection>,
    pending: HashMap<String, PendingRequest>,
    completed: HashSet<String>,
    completed_order: VecDeque<String>,
}

#[derive(Clone, Default)]
pub struct AgentRegistry {
    state: std::sync::Arc<Mutex<RegistryState>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegistryError {
    NoConnection,
    ConnectionClosed,
    DuplicateMessage,
}

impl fmt::Display for RegistryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoConnection => f.write_str("no Orialis Hermes plugin is connected"),
            Self::ConnectionClosed => f.write_str("Orialis Hermes plugin connection closed"),
            Self::DuplicateMessage => f.write_str("message has already been processed"),
        }
    }
}

impl std::error::Error for RegistryError {}

impl AgentRegistry {
    pub(crate) async fn register_connection(
        &self,
        id: String,
        user_id: String,
        device_id: String,
        platform: String,
        command_tx: mpsc::Sender<AgentCommand>,
    ) {
        let previous = {
            let mut state = self.state.lock().await;
            let previous_id = state
                .connections
                .values()
                .find(|connection| {
                    connection.user_id == user_id && connection.device_id == device_id
                })
                .map(|connection| connection.id.clone());
            let previous = if let Some(previous_id) = previous_id {
                let pending_device = state
                    .connections
                    .get(&previous_id)
                    .map(|connection| connection.device_id.clone());
                if let Some(pending_device) = pending_device {
                    state
                        .pending
                        .retain(|_, pending| pending.device_id != pending_device);
                }
                state.connections.remove(&previous_id)
            } else {
                None
            };
            let connection = AgentConnection {
                id,
                user_id,
                device_id,
                platform,
                command_tx,
            };
            state.connections.insert(connection.id.clone(), connection);
            previous
        };
        if let Some(previous) = previous {
            let _ = previous.command_tx.try_send(AgentCommand::Close);
            tracing::info!(
                device_id = %previous.device_id,
                platform = %previous.platform,
                "replaced previous Orialis Hermes plugin connection"
            );
        }
    }

    pub(crate) async fn remove_connection(&self, id: &str) {
        let mut state = self.state.lock().await;
        if let Some(connection) = state.connections.remove(id) {
            state
                .pending
                .retain(|_, pending| pending.device_id != connection.device_id);
        }
    }

    pub(crate) async fn online_agents(&self, user_id: &str) -> Vec<OnlineAgent> {
        let state = self.state.lock().await;
        let mut agents = state
            .connections
            .values()
            .filter(|connection| connection.user_id == user_id)
            .map(|connection| OnlineAgent {
                device_id: connection.device_id.clone(),
                platform: connection.platform.clone(),
            })
            .collect::<Vec<_>>();
        agents.sort_by(|left, right| left.device_id.cmp(&right.device_id));
        agents
    }

    pub(crate) async fn send_request(
        &self,
        message: GatewayMessage,
    ) -> Result<oneshot::Receiver<GatewayMessage>, RegistryError> {
        self.send_request_inner(None, None, message).await
    }

    pub(crate) async fn send_request_for_user(
        &self,
        user_id: &str,
        device_id: Option<&str>,
        message: GatewayMessage,
    ) -> Result<oneshot::Receiver<GatewayMessage>, RegistryError> {
        self.send_request_inner(Some(user_id), device_id, message)
            .await
    }

    async fn send_request_inner(
        &self,
        user_id: Option<&str>,
        device_id: Option<&str>,
        message: GatewayMessage,
    ) -> Result<oneshot::Receiver<GatewayMessage>, RegistryError> {
        let message_id = message
            .message_id()
            .ok_or(RegistryError::ConnectionClosed)?
            .to_owned();
        let (reply_tx, reply_rx) = oneshot::channel();
        let command_tx = {
            let mut state = self.state.lock().await;
            let connection = state
                .connections
                .values()
                .filter(|connection| user_id.is_none_or(|user_id| connection.user_id == user_id))
                .find(|connection| {
                    device_id.is_none_or(|device_id| connection.device_id == device_id)
                })
                .ok_or(RegistryError::NoConnection)?;
            let command_tx = connection.command_tx.clone();
            let device_id = connection.device_id.clone();
            if state.pending.contains_key(&message_id) || state.completed.contains(&message_id) {
                return Err(RegistryError::DuplicateMessage);
            }
            state.pending.insert(
                message_id.clone(),
                PendingRequest {
                    reply_tx,
                    device_id,
                },
            );
            command_tx
        };
        if command_tx.send(AgentCommand::Send(message)).await.is_err() {
            self.pending_remove(&message_id).await;
            return Err(RegistryError::ConnectionClosed);
        }
        tracing::info!(message_id = %message_id, "agent message sent to Orialis Hermes plugin");
        Ok(reply_rx)
    }

    async fn pending_remove(&self, message_id: &str) {
        self.state.lock().await.pending.remove(message_id);
    }

    pub(crate) async fn resolve_reply(&self, message: GatewayMessage) {
        let Some(reply_to) = message.reply_to() else {
            tracing::warn!("received Orialis Agent message without reply_to");
            return;
        };
        let sender = {
            let mut state = self.state.lock().await;
            let sender = state.pending.remove(reply_to);
            if sender.is_some() {
                state.completed.insert(reply_to.to_owned());
                state.completed_order.push_back(reply_to.to_owned());
                while state.completed_order.len() > COMPLETED_REQUEST_CACHE {
                    if let Some(oldest) = state.completed_order.pop_front() {
                        state.completed.remove(&oldest);
                    }
                }
            }
            sender
        };
        if let Some(pending) = sender {
            tracing::info!(reply_to = %reply_to, "agent reply received from Orialis Hermes plugin");
            let _ = pending.reply_tx.send(message);
        } else {
            tracing::warn!(reply_to = %reply_to, "received reply for unknown Orialis Agent request");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use protocol::GatewayMessage;

    #[tokio::test]
    async fn request_without_connection_is_rejected() {
        let registry = AgentRegistry::default();
        let result = registry
            .send_request(GatewayMessage::MessageSend {
                version: 1,
                message_id: "msg_1".into(),
                conversation_id: "conv_1".into(),
                content: "hello".into(),
            })
            .await;
        assert!(matches!(result, Err(RegistryError::NoConnection)));
    }

    #[tokio::test]
    async fn duplicate_request_is_rejected_before_and_after_completion() {
        let registry = AgentRegistry::default();
        let (command_tx, _command_rx) = mpsc::channel(2);
        registry
            .register_connection(
                "connection-1".into(),
                "user-1".into(),
                "device-1".into(),
                "test".into(),
                command_tx,
            )
            .await;
        let message = GatewayMessage::MessageSend {
            version: 1,
            message_id: "msg_1".into(),
            conversation_id: "conv_1".into(),
            content: "hello".into(),
        };
        let receiver = registry.send_request(message.clone()).await.unwrap();
        assert!(matches!(
            registry.send_request(message).await,
            Err(RegistryError::DuplicateMessage)
        ));
        registry
            .resolve_reply(GatewayMessage::MessageReply {
                version: 1,
                message_id: "reply_1".into(),
                reply_to: "msg_1".into(),
                conversation_id: "conv_1".into(),
                content: "done".into(),
            })
            .await;
        assert!(receiver.await.is_ok());
        assert!(matches!(
            registry
                .send_request(GatewayMessage::MessageSend {
                    version: 1,
                    message_id: "msg_1".into(),
                    conversation_id: "conv_1".into(),
                    content: "hello".into(),
                })
                .await,
            Err(RegistryError::DuplicateMessage)
        ));
    }

    #[tokio::test]
    async fn user_requests_are_routed_to_the_selected_device() {
        let registry = AgentRegistry::default();
        let (mac_tx, mut mac_rx) = mpsc::channel(2);
        let (windows_tx, mut windows_rx) = mpsc::channel(2);
        registry
            .register_connection(
                "connection-mac".into(),
                "user-1".into(),
                "device-mac".into(),
                "macos".into(),
                mac_tx,
            )
            .await;
        registry
            .register_connection(
                "connection-windows".into(),
                "user-1".into(),
                "device-windows".into(),
                "windows".into(),
                windows_tx,
            )
            .await;

        let receiver = registry
            .send_request_for_user(
                "user-1",
                Some("device-windows"),
                GatewayMessage::MessageSend {
                    version: 1,
                    message_id: "msg_windows".into(),
                    conversation_id: "conv_1".into(),
                    content: "use Windows".into(),
                },
            )
            .await
            .unwrap();
        assert!(matches!(
            windows_rx.recv().await,
            Some(AgentCommand::Send(_))
        ));
        assert!(mac_rx.try_recv().is_err());
        registry
            .resolve_reply(GatewayMessage::MessageReply {
                version: 1,
                message_id: "reply_windows".into(),
                reply_to: "msg_windows".into(),
                conversation_id: "conv_1".into(),
                content: "done".into(),
            })
            .await;
        assert!(receiver.await.is_ok());
    }

    #[tokio::test]
    async fn same_device_reconnect_does_not_remove_other_devices() {
        let registry = AgentRegistry::default();
        let (old_tx, mut old_rx) = mpsc::channel(2);
        let (other_tx, _other_rx) = mpsc::channel(2);
        let (new_tx, _new_rx) = mpsc::channel(2);
        registry
            .register_connection(
                "connection-old".into(),
                "user-1".into(),
                "device-mac".into(),
                "macos".into(),
                old_tx,
            )
            .await;
        registry
            .register_connection(
                "connection-other".into(),
                "user-1".into(),
                "device-windows".into(),
                "windows".into(),
                other_tx,
            )
            .await;
        registry
            .register_connection(
                "connection-new".into(),
                "user-1".into(),
                "device-mac".into(),
                "macos".into(),
                new_tx,
            )
            .await;
        assert!(matches!(old_rx.recv().await, Some(AgentCommand::Close)));
        assert_eq!(registry.online_agents("user-1").await.len(), 2);
    }
}
