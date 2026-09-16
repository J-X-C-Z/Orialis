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
    device_id: String,
    platform: String,
    command_tx: mpsc::Sender<AgentCommand>,
}

#[derive(Default)]
struct RegistryState {
    current: Option<AgentConnection>,
    pending: HashMap<String, oneshot::Sender<GatewayMessage>>,
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
    pub(crate) async fn replace_connection(
        &self,
        id: String,
        device_id: String,
        platform: String,
        command_tx: mpsc::Sender<AgentCommand>,
    ) {
        let previous = {
            let mut state = self.state.lock().await;
            if state.current.is_some() {
                state.pending.clear();
            }
            state.current.replace(AgentConnection {
                id,
                device_id,
                platform,
                command_tx,
            })
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
        if state
            .current
            .as_ref()
            .is_some_and(|connection| connection.id == id)
        {
            state.current = None;
            state.pending.clear();
        }
    }

    pub(crate) async fn send_request(
        &self,
        message: GatewayMessage,
    ) -> Result<oneshot::Receiver<GatewayMessage>, RegistryError> {
        let message_id = message
            .message_id()
            .ok_or(RegistryError::ConnectionClosed)?
            .to_owned();
        let (reply_tx, reply_rx) = oneshot::channel();
        let command_tx = {
            let mut state = self.state.lock().await;
            let command_tx = state
                .current
                .as_ref()
                .map(|connection| connection.command_tx.clone())
                .ok_or(RegistryError::NoConnection)?;
            if state.pending.contains_key(&message_id) || state.completed.contains(&message_id) {
                return Err(RegistryError::DuplicateMessage);
            }
            state.pending.insert(message_id.clone(), reply_tx);
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
        if let Some(sender) = sender {
            tracing::info!(reply_to = %reply_to, "agent reply received from Orialis Hermes plugin");
            let _ = sender.send(message);
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
            .replace_connection(
                "connection-1".into(),
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
}
