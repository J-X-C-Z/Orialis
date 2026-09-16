//! The Agent Track boundary between Orialis Server and a Hermes platform plugin.

pub mod protocol;
pub mod ws;

use protocol::GatewayMessage;
use std::{
    collections::{HashMap, HashSet, VecDeque},
    fmt,
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, Mutex};

const COMPLETED_REQUEST_CACHE: usize = 4096;
const EVENT_CACHE: usize = 4096;
const DEFAULT_APPROVAL_TIMEOUT: Duration = Duration::from_secs(120);
const MAX_APPROVAL_TIMEOUT: Duration = Duration::from_secs(24 * 60 * 60);
pub(crate) const SERVER_CAPABILITIES: &[&str] = &[
    "agent.typing",
    "agent.start",
    "agent.delta",
    "agent.complete",
    "agent.error",
    "agent.status",
    "tool.started",
    "tool.progress",
    "tool.completed",
    "tool.failed",
    "clarify.request",
    "clarify.resolve",
    "clarify.cancel",
    "approval.request",
    "approval.resolve",
    "session.start",
    "session.update",
    "session.complete",
    "session.cancel",
    "session.error",
    "artifact.started",
    "artifact.progress",
    "artifact.completed",
    "artifact.failed",
];

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

#[derive(Default)]
struct DeviceEventState {
    last_inbound_seq: u64,
    seen_event_ids: HashSet<String>,
    seen_event_order: VecDeque<String>,
    inbound_events: VecDeque<GatewayMessage>,
    next_outbound_seq: u64,
    outbound_events: VecDeque<GatewayMessage>,
    pending_approvals: HashMap<String, PendingApproval>,
    resolved_approvals: HashSet<String>,
    resolved_approval_order: VecDeque<String>,
}

struct PendingApproval {
    expires_at: Instant,
    session_id: String,
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
    events: HashMap<String, DeviceEventState>,
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum EventDisposition {
    Accepted,
    Duplicate,
    Gap { expected_seq: u64 },
    UnknownApproval,
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

    pub(crate) async fn accept_event(
        &self,
        device_id: &str,
        message: GatewayMessage,
    ) -> EventDisposition {
        let Some((event_id, seq, _)) = message.event_metadata() else {
            return EventDisposition::UnknownApproval;
        };
        let mut state = self.state.lock().await;
        let events = state.events.entry(device_id.to_owned()).or_default();
        if events.seen_event_ids.contains(event_id) || seq <= events.last_inbound_seq {
            return EventDisposition::Duplicate;
        }
        if seq > events.last_inbound_seq.saturating_add(1) {
            return EventDisposition::Gap {
                expected_seq: events.last_inbound_seq.saturating_add(1),
            };
        }

        let mut disposition = EventDisposition::Accepted;
        if let GatewayMessage::ApprovalRequest {
            request_id,
            timeout_ms,
            ..
        } = &message
        {
            if events.pending_approvals.contains_key(request_id)
                || events.resolved_approvals.contains(request_id)
            {
                disposition = EventDisposition::Duplicate;
            } else {
                let timeout = timeout_ms
                    .map(|value| Duration::from_millis(value).min(MAX_APPROVAL_TIMEOUT))
                    .unwrap_or(DEFAULT_APPROVAL_TIMEOUT);
                events.pending_approvals.insert(
                    request_id.clone(),
                    PendingApproval {
                        expires_at: Instant::now() + timeout,
                        session_id: session_id_for(&message),
                    },
                );
            }
        } else if let GatewayMessage::ApprovalResolve { request_id, .. } = &message {
            if events.pending_approvals.remove(request_id).is_none() {
                disposition = EventDisposition::UnknownApproval;
            } else {
                remember_resolved_approval(events, request_id);
            }
        }

        events.last_inbound_seq = seq;
        remember_event_id(events, event_id);
        events.inbound_events.push_back(message);
        while events.inbound_events.len() > EVENT_CACHE {
            events.inbound_events.pop_front();
        }
        disposition
    }

    pub(crate) async fn expire_approvals(&self, device_id: &str) -> Vec<(String, String)> {
        let mut state = self.state.lock().await;
        let events = state.events.entry(device_id.to_owned()).or_default();
        let now = Instant::now();
        let expired = events
            .pending_approvals
            .iter()
            .filter_map(|(request_id, approval)| {
                (approval.expires_at <= now)
                    .then_some((request_id.clone(), approval.session_id.clone()))
            })
            .collect::<Vec<_>>();
        for (request_id, _) in &expired {
            events.pending_approvals.remove(request_id);
            remember_resolved_approval(events, request_id);
        }
        expired
    }

    pub(crate) async fn capabilities_ack(
        &self,
        device_id: &str,
        resume_from: u64,
    ) -> GatewayMessage {
        let mut state = self.state.lock().await;
        let events = state.events.entry(device_id.to_owned()).or_default();
        GatewayMessage::CapabilitiesAck {
            version: protocol::PROTOCOL_VERSION,
            capabilities: SERVER_CAPABILITIES
                .iter()
                .map(|value| (*value).into())
                .collect(),
            resume_from: resume_from.min(events.next_outbound_seq.saturating_sub(1)),
            next_seq: events.next_outbound_seq.max(1),
        }
    }

    pub(crate) async fn replay_after(
        &self,
        device_id: &str,
        resume_from: u64,
    ) -> Vec<GatewayMessage> {
        let state = self.state.lock().await;
        state
            .events
            .get(device_id)
            .map(|events| {
                events
                    .outbound_events
                    .iter()
                    .filter(|message| {
                        message
                            .event_metadata()
                            .is_some_and(|(_, seq, _)| seq > resume_from)
                    })
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    pub(crate) async fn record_server_event(
        &self,
        device_id: &str,
        message: GatewayMessage,
    ) -> Option<GatewayMessage> {
        if message.event_metadata().is_none() {
            return None;
        }
        let mut state = self.state.lock().await;
        let events = state.events.entry(device_id.to_owned()).or_default();
        events.next_outbound_seq = events.next_outbound_seq.saturating_add(1).max(1);
        let event = message.with_seq(events.next_outbound_seq);
        events.outbound_events.push_back(event.clone());
        while events.outbound_events.len() > EVENT_CACHE {
            events.outbound_events.pop_front();
        }
        Some(event)
    }

    /// Queue a structured event for a device and assign its server sequence.
    /// Current callers may still use the durable message queue; this method is
    /// the transport hook for future server-originated session/tool events.
    pub(crate) async fn send_event_for_user(
        &self,
        user_id: &str,
        device_id: Option<&str>,
        message: GatewayMessage,
    ) -> Result<GatewayMessage, RegistryError> {
        if message.event_metadata().is_none() {
            return Err(RegistryError::ConnectionClosed);
        }
        let (command_tx, event) = {
            let mut state = self.state.lock().await;
            let (connection_device_id, connection_command_tx) = state
                .connections
                .values()
                .find(|connection| {
                    connection.user_id == user_id
                        && device_id.is_none_or(|device_id| connection.device_id == device_id)
                })
                .map(|connection| (connection.device_id.clone(), connection.command_tx.clone()))
                .ok_or(RegistryError::NoConnection)?;
            let event_id = message.event_metadata().map(|(id, _, _)| id.to_owned());
            let events = state.events.entry(connection_device_id).or_default();
            if event_id.is_some_and(|id| {
                events.seen_event_ids.contains(&id)
                    || events.outbound_events.iter().any(|event| {
                        event
                            .event_metadata()
                            .is_some_and(|(existing, _, _)| existing == id)
                    })
            }) {
                return Err(RegistryError::DuplicateMessage);
            }
            events.next_outbound_seq = events.next_outbound_seq.saturating_add(1).max(1);
            let event = message.with_seq(events.next_outbound_seq);
            events.outbound_events.push_back(event.clone());
            while events.outbound_events.len() > EVENT_CACHE {
                events.outbound_events.pop_front();
            }
            (connection_command_tx, event)
        };
        command_tx
            .send(AgentCommand::Send(event.clone()))
            .await
            .map_err(|_| RegistryError::ConnectionClosed)?;
        Ok(event)
    }
}

fn remember_event_id(events: &mut DeviceEventState, event_id: &str) {
    if events.seen_event_ids.insert(event_id.to_owned()) {
        events.seen_event_order.push_back(event_id.to_owned());
        while events.seen_event_order.len() > EVENT_CACHE {
            if let Some(oldest) = events.seen_event_order.pop_front() {
                events.seen_event_ids.remove(&oldest);
            }
        }
    }
}

fn remember_resolved_approval(events: &mut DeviceEventState, request_id: &str) {
    if events.resolved_approvals.insert(request_id.to_owned()) {
        events
            .resolved_approval_order
            .push_back(request_id.to_owned());
        while events.resolved_approval_order.len() > EVENT_CACHE {
            if let Some(oldest) = events.resolved_approval_order.pop_front() {
                events.resolved_approvals.remove(&oldest);
            }
        }
    }
}

fn session_id_for(message: &GatewayMessage) -> String {
    message
        .event_metadata()
        .map(|(_, _, session_id)| session_id.to_owned())
        .unwrap_or_default()
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
                attachments: vec![],
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
            attachments: vec![],
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
                attachments: vec![],
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
                    attachments: vec![],
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
                    attachments: vec![],
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
                attachments: vec![],
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

    fn agent_status(event_id: &str, seq: u64) -> GatewayMessage {
        GatewayMessage::AgentStatus {
            version: protocol::PROTOCOL_VERSION,
            event_id: event_id.into(),
            seq,
            session_id: "session-1".into(),
            status: "running".into(),
            message: None,
        }
    }

    #[tokio::test]
    async fn event_sequence_is_idempotent_and_survives_reconnect() {
        let registry = AgentRegistry::default();
        assert_eq!(
            registry
                .accept_event("device-1", agent_status("event-1", 1))
                .await,
            EventDisposition::Accepted
        );
        assert_eq!(
            registry
                .accept_event("device-1", agent_status("event-1", 1))
                .await,
            EventDisposition::Duplicate
        );
        assert_eq!(
            registry
                .accept_event("device-1", agent_status("event-3", 3))
                .await,
            EventDisposition::Gap { expected_seq: 2 }
        );
        assert_eq!(
            registry
                .accept_event("device-1", agent_status("event-2", 2))
                .await,
            EventDisposition::Accepted
        );
        assert_eq!(
            registry.replay_after("device-1", 0).await,
            Vec::<GatewayMessage>::new()
        );
    }

    #[tokio::test]
    async fn approvals_are_resolved_once_and_expire() {
        let registry = AgentRegistry::default();
        let request = GatewayMessage::ApprovalRequest {
            version: protocol::PROTOCOL_VERSION,
            event_id: "approval-event-1".into(),
            seq: 1,
            session_id: "session-1".into(),
            request_id: "approval-1".into(),
            action: "calendar.write".into(),
            details: serde_json::json!({"title": "demo"}),
            timeout_ms: Some(0),
        };
        assert_eq!(
            registry.accept_event("device-1", request.clone()).await,
            EventDisposition::Accepted
        );
        assert_eq!(
            registry.accept_event("device-1", request).await,
            EventDisposition::Duplicate
        );
        assert_eq!(
            registry.expire_approvals("device-1").await,
            vec![("approval-1".into(), "session-1".into())]
        );
        let resolve = GatewayMessage::ApprovalResolve {
            version: protocol::PROTOCOL_VERSION,
            event_id: "approval-event-2".into(),
            seq: 2,
            session_id: "session-1".into(),
            request_id: "approval-1".into(),
            decision: protocol::ApprovalDecision::Once,
            reason: None,
        };
        assert_eq!(
            registry.accept_event("device-1", resolve).await,
            EventDisposition::UnknownApproval
        );
    }

    #[tokio::test]
    async fn server_events_receive_sequences_and_can_be_replayed() {
        let registry = AgentRegistry::default();
        let (command_tx, mut command_rx) = mpsc::channel(2);
        registry
            .register_connection(
                "connection-1".into(),
                "user-1".into(),
                "device-1".into(),
                "test".into(),
                command_tx,
            )
            .await;
        let sent = registry
            .send_event_for_user("user-1", Some("device-1"), agent_status("server-1", 0))
            .await
            .unwrap();
        assert_eq!(sent.event_metadata().map(|(_, seq, _)| seq), Some(1));
        assert!(matches!(
            command_rx.recv().await,
            Some(AgentCommand::Send(_))
        ));
        assert_eq!(registry.replay_after("device-1", 0).await.len(), 1);
        assert_eq!(registry.replay_after("device-1", 1).await.len(), 0);
    }
}
