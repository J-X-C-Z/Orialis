//! Versioned JSON wire types for the Orialis ↔ Hermes Agent Gateway MVP.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{fmt, str::FromStr};

pub const PROTOCOL_VERSION: u32 = 1;

/// Stable Agent device IDs use `<USER>_<DEVICE>_<Agent>`, for example
/// `JXCZ_MBA_Hermes`. Case is intentionally not significant.
pub fn is_valid_agent_device_id(value: &str) -> bool {
    if value.len() > 80 {
        return false;
    }
    let mut segments = value.split('_');
    let (Some(owner), Some(device), Some(agent)) =
        (segments.next(), segments.next(), segments.next())
    else {
        return false;
    };
    if segments.next().is_some()
        || !(2..=24).contains(&owner.len())
        || !(2..=24).contains(&device.len())
        || !(2..=24).contains(&agent.len())
        || !owner.bytes().all(|byte| byte.is_ascii_alphanumeric())
        || !device.bytes().all(|byte| byte.is_ascii_alphanumeric())
    {
        return false;
    }
    agent.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

/// Stable envelope used by the ordinary mobile WebSocket channel.
///
/// The Hermes channel below intentionally keeps its legacy wire shape. Mobile
/// clients use this envelope so new server hints can be added without making
/// clients deserialize unrelated top-level fields.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MobileEnvelope {
    pub version: u32,
    #[serde(rename = "type")]
    pub message_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub payload: Value,
}

pub const MOBILE_HELLO: &str = "hello";
pub const MOBILE_HELLO_ACK: &str = "hello.ack";
pub const MOBILE_PING: &str = "ping";
pub const MOBILE_PONG: &str = "pong";
pub const MOBILE_EVENT: &str = "event";
pub const MOBILE_MESSAGE: &str = "message";
pub const MOBILE_SYNC_CHANGE_HINT: &str = "sync.change_hint";
pub const MOBILE_ERROR: &str = "error";

const MOBILE_TYPES: &[&str] = &[
    MOBILE_HELLO,
    MOBILE_HELLO_ACK,
    MOBILE_PING,
    MOBILE_PONG,
    MOBILE_EVENT,
    MOBILE_MESSAGE,
    MOBILE_SYNC_CHANGE_HINT,
    MOBILE_ERROR,
];

pub fn parse_mobile_envelope(input: &str) -> Result<MobileEnvelope, ProtocolError> {
    let envelope: MobileEnvelope =
        serde_json::from_str(input).map_err(|_| ProtocolError::InvalidJson)?;
    if envelope.version != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(envelope.version));
    }
    if !MOBILE_TYPES.contains(&envelope.message_type.as_str()) {
        return Err(ProtocolError::UnknownType(envelope.message_type));
    }
    if !envelope.payload.is_object() {
        return Err(ProtocolError::InvalidMessage);
    }
    Ok(envelope)
}

pub fn mobile_envelope(
    message_type: &'static str,
    request_id: Option<String>,
    payload: Value,
) -> MobileEnvelope {
    MobileEnvelope {
        version: PROTOCOL_VERSION,
        message_type: message_type.to_owned(),
        request_id,
        payload,
    }
}

pub fn mobile_error(code: &str, message: &str, request_id: Option<String>) -> MobileEnvelope {
    mobile_envelope(
        MOBILE_ERROR,
        request_id,
        serde_json::json!({ "code": code, "message": message }),
    )
}

pub fn mobile_event(payload: Value) -> MobileEnvelope {
    mobile_envelope(MOBILE_EVENT, None, payload)
}

pub fn mobile_message(payload: Value) -> MobileEnvelope {
    mobile_envelope(MOBILE_MESSAGE, None, payload)
}

pub fn mobile_sync_change_hint(cursor: i64, entity: Option<&str>) -> MobileEnvelope {
    let mut payload = serde_json::json!({ "cursor": cursor });
    if let Some(entity) = entity {
        payload["entity"] = Value::String(entity.to_owned());
    }
    mobile_envelope(MOBILE_SYNC_CHANGE_HINT, None, payload)
}

/// Attachment metadata carried on the Agent Gateway WebSocket.
///
/// The file bytes are uploaded over HTTP; WebSocket frames only carry a
/// server-issued ID and canonical metadata.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GatewayAttachment {
    pub id: String,
    pub name: String,
    pub mime_type: String,
    pub size: i64,
    pub download_url: String,
}

/// Decisions are deliberately transport-level values.  The server does not
/// decide what a Hermes tool is allowed to do; it only carries the decision
/// and prevents the same approval request from being resolved twice.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum ApprovalDecision {
    #[serde(rename = "once")]
    Once,
    #[serde(rename = "session")]
    Session,
    #[serde(rename = "always")]
    Always,
    #[serde(rename = "deny")]
    Deny,
    #[serde(rename = "timeout")]
    Timeout,
    #[serde(rename = "cancelled", alias = "canceled")]
    Cancelled,
    #[serde(rename = "approved")]
    Approved,
    #[serde(rename = "denied")]
    Denied,
    #[serde(rename = "expired")]
    Expired,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GatewayArtifact {
    pub id: String,
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uri: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub download_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type")]
pub enum GatewayMessage {
    #[serde(rename = "hello")]
    Hello {
        version: u32,
        device_id: String,
        client: String,
        plugin_version: String,
        platform: String,
    },
    #[serde(rename = "hello_ack")]
    HelloAck { version: u32 },
    #[serde(rename = "ping")]
    Ping { version: u32 },
    #[serde(rename = "pong")]
    Pong { version: u32 },
    #[serde(rename = "message.send")]
    MessageSend {
        version: u32,
        message_id: String,
        conversation_id: String,
        content: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        attachments: Vec<GatewayAttachment>,
    },
    #[serde(rename = "message.reply")]
    MessageReply {
        version: u32,
        message_id: String,
        reply_to: String,
        conversation_id: String,
        content: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        attachments: Vec<GatewayAttachment>,
    },
    #[serde(rename = "message.ack")]
    MessageAck {
        version: u32,
        message_id: String,
        status: String,
    },
    #[serde(rename = "error")]
    Error {
        version: u32,
        code: String,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        reply_to: Option<String>,
    },
    /// Generic v0.3 event envelope. Named event variants below provide the
    /// flat v1.x transport while this form remains schema-compatible.
    #[serde(rename = "event")]
    Event {
        version: u32,
        event_id: String,
        event_type: String,
        sequence: u64,
        occurred_at: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        correlation_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        causation_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        idempotency_key: Option<String>,
        payload: Value,
    },
    #[serde(rename = "capabilities.hello")]
    CapabilitiesHello {
        version: u32,
        capabilities: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        resume_from: Option<u64>,
    },
    #[serde(rename = "capabilities.ack")]
    CapabilitiesAck {
        version: u32,
        capabilities: Vec<String>,
        resume_from: u64,
        next_seq: u64,
    },
    #[serde(rename = "agent.ack")]
    AgentAck {
        version: u32,
        event_id: String,
        seq: u64,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        expected_seq: Option<u64>,
    },
    #[serde(rename = "agent.typing")]
    AgentTyping {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run_id: Option<String>,
        typing: bool,
    },
    #[serde(rename = "agent.start", alias = "agent.started")]
    AgentStart {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        run_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation_id: Option<String>,
    },
    #[serde(rename = "agent.delta")]
    AgentDelta {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        run_id: String,
        delta: String,
    },
    #[serde(rename = "agent.complete", alias = "agent.completed")]
    AgentComplete {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        run_id: String,
        content: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        artifacts: Vec<GatewayArtifact>,
    },
    #[serde(rename = "agent.error", alias = "agent.failed")]
    AgentError {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        run_id: String,
        code: String,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        retryable: Option<bool>,
    },
    #[serde(rename = "agent.status")]
    AgentStatus {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        status: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    #[serde(rename = "tool.started")]
    ToolStarted {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        tool_call_id: String,
        tool_name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        input: Option<Value>,
    },
    #[serde(rename = "tool.progress")]
    ToolProgress {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        tool_call_id: String,
        progress: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    #[serde(rename = "tool.completed")]
    ToolCompleted {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        tool_call_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        output: Option<Value>,
    },
    #[serde(rename = "tool.failed")]
    ToolFailed {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        tool_call_id: String,
        code: String,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        retryable: Option<bool>,
    },
    #[serde(rename = "clarify.request", alias = "clarify.requested")]
    ClarifyRequest {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        request_id: String,
        question: String,
        /// Gateway wire name is `choices`; `options` is the card-facing alias.
        #[serde(default, alias = "choices", skip_serializing_if = "Vec::is_empty")]
        options: Vec<Value>,
    },
    #[serde(rename = "clarify.resolve", alias = "clarify.responded")]
    ClarifyResolve {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        request_id: String,
        answer: Value,
    },
    #[serde(rename = "clarify.cancel")]
    ClarifyCancel {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        request_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "approval.request", alias = "approval.requested")]
    ApprovalRequest {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        request_id: String,
        action: String,
        #[serde(default)]
        details: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_ms: Option<u64>,
    },
    #[serde(rename = "approval.resolve", alias = "approval.responded")]
    ApprovalResolve {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        request_id: String,
        decision: ApprovalDecision,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(
        rename = "session.start",
        alias = "session.started",
        alias = "session.created"
    )]
    SessionStart {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        conversation_id: Option<String>,
    },
    #[serde(rename = "session.update")]
    SessionUpdate {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        update: Value,
    },
    #[serde(rename = "session.complete", alias = "session.completed")]
    SessionComplete {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        result: Option<Value>,
    },
    #[serde(rename = "session.resumed")]
    SessionResumed {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        last_sequence: u64,
    },
    #[serde(rename = "session.ended")]
    SessionEnded {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        reason: String,
    },
    #[serde(rename = "session.cancel", alias = "session.cancelled")]
    SessionCancel {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "session.error", alias = "session.failed")]
    SessionError {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        code: String,
        message: String,
    },
    #[serde(rename = "artifact.started", alias = "artifact.created")]
    ArtifactStarted {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        artifact: GatewayArtifact,
    },
    #[serde(rename = "artifact.progress")]
    ArtifactProgress {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        artifact_id: String,
        progress: Value,
    },
    #[serde(rename = "artifact.completed", alias = "artifact.ready")]
    ArtifactCompleted {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        artifact: GatewayArtifact,
    },
    #[serde(rename = "artifact.failed")]
    ArtifactFailed {
        version: u32,
        event_id: String,
        seq: u64,
        session_id: String,
        artifact_id: String,
        code: String,
        message: String,
    },
}

impl GatewayMessage {
    pub fn message_id(&self) -> Option<&str> {
        match self {
            Self::MessageSend { message_id, .. }
            | Self::MessageReply { message_id, .. }
            | Self::MessageAck { message_id, .. } => Some(message_id),
            _ => None,
        }
    }

    pub fn reply_to(&self) -> Option<&str> {
        match self {
            Self::MessageReply { reply_to, .. }
            | Self::Error {
                reply_to: Some(reply_to),
                ..
            } => Some(reply_to),
            _ => None,
        }
    }

    pub fn event_metadata(&self) -> Option<(&str, u64, &str)> {
        match self {
            Self::Event {
                event_id,
                sequence,
                session_id,
                ..
            } => Some((event_id, *sequence, session_id.as_deref().unwrap_or(""))),
            Self::AgentTyping {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::AgentStart {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::AgentDelta {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::AgentComplete {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::AgentError {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::AgentStatus {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ToolStarted {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ToolProgress {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ToolCompleted {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ToolFailed {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ClarifyRequest {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ClarifyResolve {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ClarifyCancel {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ApprovalRequest {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ApprovalResolve {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionStart {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionUpdate {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionComplete {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionResumed {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionEnded {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionCancel {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::SessionError {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ArtifactStarted {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ArtifactProgress {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ArtifactCompleted {
                event_id,
                seq,
                session_id,
                ..
            }
            | Self::ArtifactFailed {
                event_id,
                seq,
                session_id,
                ..
            } => Some((event_id, *seq, session_id)),
            _ => None,
        }
    }

    pub fn with_seq(mut self, seq: u64) -> Self {
        match &mut self {
            Self::Event {
                sequence: value, ..
            } => *value = seq,
            Self::AgentTyping { seq: value, .. }
            | Self::AgentStart { seq: value, .. }
            | Self::AgentDelta { seq: value, .. }
            | Self::AgentComplete { seq: value, .. }
            | Self::AgentError { seq: value, .. }
            | Self::AgentStatus { seq: value, .. }
            | Self::ToolStarted { seq: value, .. }
            | Self::ToolProgress { seq: value, .. }
            | Self::ToolCompleted { seq: value, .. }
            | Self::ToolFailed { seq: value, .. }
            | Self::ClarifyRequest { seq: value, .. }
            | Self::ClarifyResolve { seq: value, .. }
            | Self::ClarifyCancel { seq: value, .. }
            | Self::ApprovalRequest { seq: value, .. }
            | Self::ApprovalResolve { seq: value, .. }
            | Self::SessionStart { seq: value, .. }
            | Self::SessionUpdate { seq: value, .. }
            | Self::SessionComplete { seq: value, .. }
            | Self::SessionResumed { seq: value, .. }
            | Self::SessionEnded { seq: value, .. }
            | Self::SessionCancel { seq: value, .. }
            | Self::SessionError { seq: value, .. }
            | Self::ArtifactStarted { seq: value, .. }
            | Self::ArtifactProgress { seq: value, .. }
            | Self::ArtifactCompleted { seq: value, .. }
            | Self::ArtifactFailed { seq: value, .. } => *value = seq,
            _ => {}
        }
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProtocolError {
    InvalidJson,
    InvalidEnvelope,
    MissingType,
    UnsupportedVersion(u32),
    UnknownType(String),
    InvalidMessage,
    InvalidDeviceId,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidJson => f.write_str("invalid JSON"),
            Self::InvalidEnvelope => f.write_str("message must be a JSON object"),
            Self::MissingType => f.write_str("missing type"),
            Self::UnsupportedVersion(version) => {
                write!(f, "unsupported protocol version {version}")
            }
            Self::UnknownType(message_type) => write!(f, "unknown message type {message_type}"),
            Self::InvalidMessage => {
                f.write_str("message is missing required fields or has invalid fields")
            }
            Self::InvalidDeviceId => {
                f.write_str("device_id must use <USER>_<DEVICE>_<Agent> format")
            }
        }
    }
}

impl std::error::Error for ProtocolError {}

pub fn parse_message(input: &str) -> Result<GatewayMessage, ProtocolError> {
    let value = Value::from_str(input).map_err(|_| ProtocolError::InvalidJson)?;
    let object = value.as_object().ok_or(ProtocolError::InvalidEnvelope)?;
    let version = object
        .get("version")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or(ProtocolError::InvalidMessage)?;
    if version != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(version));
    }
    let message_type = object
        .get("type")
        .and_then(Value::as_str)
        .ok_or(ProtocolError::MissingType)?;
    if !matches!(
        message_type,
        "hello"
            | "hello_ack"
            | "ping"
            | "pong"
            | "message.send"
            | "message.reply"
            | "message.ack"
            | "error"
            | "event"
            | "capabilities.hello"
            | "capabilities.ack"
            | "agent.ack"
            | "agent.typing"
            | "agent.start"
            | "agent.started"
            | "agent.delta"
            | "agent.complete"
            | "agent.completed"
            | "agent.error"
            | "agent.failed"
            | "agent.status"
            | "tool.started"
            | "tool.progress"
            | "tool.completed"
            | "tool.failed"
            | "clarify.request"
            | "clarify.requested"
            | "clarify.responded"
            | "clarify.resolve"
            | "clarify.cancel"
            | "approval.request"
            | "approval.requested"
            | "approval.responded"
            | "approval.resolve"
            | "session.start"
            | "session.started"
            | "session.created"
            | "session.update"
            | "session.complete"
            | "session.completed"
            | "session.resumed"
            | "session.ended"
            | "session.cancel"
            | "session.cancelled"
            | "session.error"
            | "session.failed"
            | "artifact.started"
            | "artifact.created"
            | "artifact.progress"
            | "artifact.completed"
            | "artifact.ready"
            | "artifact.failed"
    ) {
        return Err(ProtocolError::UnknownType(message_type.to_owned()));
    }
    let message: GatewayMessage =
        serde_json::from_value(value).map_err(|_| ProtocolError::InvalidMessage)?;
    validate_message(&message)?;
    Ok(message)
}

fn validate_text(value: &str) -> Result<(), ProtocolError> {
    if value.trim().is_empty() {
        Err(ProtocolError::InvalidMessage)
    } else {
        Ok(())
    }
}

fn validate_attachments(attachments: &[GatewayAttachment]) -> Result<(), ProtocolError> {
    if attachments.len() > 16 {
        return Err(ProtocolError::InvalidMessage);
    }
    for attachment in attachments {
        for value in [
            &attachment.id,
            &attachment.name,
            &attachment.mime_type,
            &attachment.download_url,
        ] {
            validate_text(value)?;
        }
        if attachment.name.chars().count() > 180 || attachment.size < 1 {
            return Err(ProtocolError::InvalidMessage);
        }
        let mime = attachment.mime_type.to_ascii_lowercase();
        if mime.starts_with("audio/") || mime.starts_with("video/") {
            return Err(ProtocolError::InvalidMessage);
        }
        if !(mime.starts_with("image/")
            || mime.starts_with("text/")
            || matches!(
                mime.as_str(),
                "application/pdf"
                    | "application/json"
                    | "application/xml"
                    | "application/octet-stream"
                    | "application/zip"
            ))
        {
            return Err(ProtocolError::InvalidMessage);
        }
    }
    Ok(())
}

fn validate_message_text_or_attachments(
    content: &str,
    attachments: &[GatewayAttachment],
) -> Result<(), ProtocolError> {
    if content.trim().is_empty() && attachments.is_empty() {
        return Err(ProtocolError::InvalidMessage);
    }
    validate_attachments(attachments)
}

fn validate_message(message: &GatewayMessage) -> Result<(), ProtocolError> {
    match message {
        GatewayMessage::Hello {
            device_id,
            client,
            plugin_version,
            platform,
            ..
        } => {
            for value in [device_id, client, plugin_version, platform] {
                validate_text(value)?;
            }
            if !is_valid_agent_device_id(device_id) {
                return Err(ProtocolError::InvalidDeviceId);
            }
        }
        GatewayMessage::MessageSend {
            message_id,
            conversation_id,
            content,
            attachments,
            ..
        } => {
            for value in [message_id, conversation_id] {
                validate_text(value)?;
            }
            validate_message_text_or_attachments(content, attachments)?;
        }
        GatewayMessage::MessageReply {
            message_id,
            reply_to,
            conversation_id,
            content,
            attachments,
            ..
        } => {
            for value in [message_id, reply_to, conversation_id] {
                validate_text(value)?;
            }
            validate_message_text_or_attachments(content, attachments)?;
        }
        GatewayMessage::MessageAck {
            message_id, status, ..
        } => {
            validate_text(message_id)?;
            validate_text(status)?;
        }
        GatewayMessage::Error {
            code,
            message,
            reply_to,
            ..
        } => {
            validate_text(code)?;
            validate_text(message)?;
            if let Some(reply_to) = reply_to {
                validate_text(reply_to)?;
            }
        }
        GatewayMessage::CapabilitiesHello { capabilities, .. } => {
            validate_capabilities(capabilities)?;
        }
        GatewayMessage::CapabilitiesAck { capabilities, .. } => {
            validate_capabilities(capabilities)?;
        }
        GatewayMessage::AgentAck {
            event_id,
            status,
            seq,
            expected_seq,
            ..
        } => {
            validate_text(event_id)?;
            validate_text(status)?;
            if *seq == 0 || expected_seq.is_some_and(|value| value == 0) {
                return Err(ProtocolError::InvalidMessage);
            }
        }
        message if message.event_metadata().is_some() => validate_event(message)?,
        GatewayMessage::HelloAck { .. }
        | GatewayMessage::Ping { .. }
        | GatewayMessage::Pong { .. } => {}
        // Capability and delivery control messages are structurally validated
        // by serde and do not carry user-authored text constraints here.
        _ => {}
    }
    Ok(())
}

fn validate_capabilities(capabilities: &[String]) -> Result<(), ProtocolError> {
    if capabilities.len() > 128 {
        return Err(ProtocolError::InvalidMessage);
    }
    for capability in capabilities {
        validate_text(capability)?;
        if capability.len() > 120 {
            return Err(ProtocolError::InvalidMessage);
        }
    }
    Ok(())
}

fn validate_event(message: &GatewayMessage) -> Result<(), ProtocolError> {
    let Some((event_id, seq, session_id)) = message.event_metadata() else {
        return Err(ProtocolError::InvalidMessage);
    };
    if let GatewayMessage::Event {
        event_type,
        occurred_at,
        session_id,
        correlation_id,
        causation_id,
        idempotency_key,
        payload,
        ..
    } = message
    {
        validate_text(event_id)?;
        validate_text(event_type)?;
        validate_text(occurred_at)?;
        if chrono::DateTime::parse_from_rfc3339(occurred_at).is_err() {
            return Err(ProtocolError::InvalidMessage);
        }
        if !supported_event_type(event_type) || seq == 0 || !payload.is_object() {
            return Err(if !supported_event_type(event_type) {
                ProtocolError::UnknownType(event_type.clone())
            } else {
                ProtocolError::InvalidMessage
            });
        }
        if event_type.starts_with("artifact.") {
            if payload
                .get("mime_type")
                .and_then(Value::as_str)
                .is_some_and(|mime| {
                    let mime = mime.to_ascii_lowercase();
                    mime.starts_with("audio/") || mime.starts_with("video/")
                })
            {
                return Err(ProtocolError::InvalidMessage);
            }
        }
        for value in [session_id, correlation_id, causation_id, idempotency_key]
            .into_iter()
            .flatten()
        {
            validate_text(value)?;
        }
        return Ok(());
    }
    for value in [event_id, session_id] {
        validate_text(value)?;
    }
    if seq == 0 {
        return Err(ProtocolError::InvalidMessage);
    }
    match message {
        GatewayMessage::AgentStart {
            run_id,
            conversation_id,
            ..
        } => {
            validate_text(run_id)?;
            if let Some(value) = conversation_id {
                validate_text(value)?;
            }
        }
        GatewayMessage::AgentDelta { run_id, delta, .. } => {
            validate_text(run_id)?;
            if delta.is_empty() {
                return Err(ProtocolError::InvalidMessage);
            }
        }
        GatewayMessage::AgentComplete { run_id, .. } => validate_text(run_id)?,
        GatewayMessage::AgentError {
            run_id,
            code,
            message,
            ..
        } => {
            validate_text(run_id)?;
            validate_text(code)?;
            validate_text(message)?;
        }
        GatewayMessage::ToolFailed {
            tool_call_id,
            code,
            message,
            ..
        } => {
            validate_text(tool_call_id)?;
            validate_text(code)?;
            validate_text(message)?;
        }
        GatewayMessage::SessionError { code, message, .. } => {
            validate_text(code)?;
            validate_text(message)?;
        }
        GatewayMessage::AgentStatus {
            status, message, ..
        } => {
            validate_text(status)?;
            if let Some(value) = message {
                validate_text(value)?;
            }
        }
        GatewayMessage::ToolStarted {
            tool_call_id,
            tool_name,
            ..
        } => {
            validate_text(tool_call_id)?;
            validate_text(tool_name)?;
        }
        GatewayMessage::ToolProgress { tool_call_id, .. }
        | GatewayMessage::ToolCompleted { tool_call_id, .. } => validate_text(tool_call_id)?,
        GatewayMessage::ClarifyRequest {
            request_id,
            question,
            ..
        } => {
            validate_text(request_id)?;
            validate_text(question)?;
        }
        GatewayMessage::ClarifyResolve { request_id, .. }
        | GatewayMessage::ClarifyCancel { request_id, .. } => validate_text(request_id)?,
        GatewayMessage::ApprovalRequest {
            request_id, action, ..
        } => {
            validate_text(request_id)?;
            validate_text(action)?;
        }
        GatewayMessage::ApprovalResolve { request_id, .. } => validate_text(request_id)?,
        GatewayMessage::SessionStart {
            conversation_id, ..
        } => {
            if let Some(value) = conversation_id {
                validate_text(value)?;
            }
        }
        GatewayMessage::SessionUpdate { update, .. } => {
            if !update.is_object() {
                return Err(ProtocolError::InvalidMessage);
            }
        }
        GatewayMessage::SessionCancel { reason, .. } => {
            if let Some(value) = reason {
                validate_text(value)?;
            }
        }
        GatewayMessage::ArtifactStarted { artifact, .. }
        | GatewayMessage::ArtifactCompleted { artifact, .. } => validate_artifact(artifact)?,
        GatewayMessage::ArtifactProgress { artifact_id, .. } => validate_text(artifact_id)?,
        GatewayMessage::ArtifactFailed {
            artifact_id,
            code,
            message,
            ..
        } => {
            validate_text(artifact_id)?;
            validate_text(code)?;
            validate_text(message)?;
        }
        GatewayMessage::AgentTyping { .. }
        | GatewayMessage::SessionComplete { .. }
        | GatewayMessage::SessionResumed { .. } => {}
        GatewayMessage::SessionEnded { reason, .. } => validate_text(reason)?,
        _ => return Err(ProtocolError::InvalidMessage),
    }
    Ok(())
}

fn supported_event_type(event_type: &str) -> bool {
    matches!(
        event_type,
        "agent.typing"
            | "agent.start"
            | "agent.delta"
            | "agent.complete"
            | "agent.error"
            | "agent.status"
            | "tool.started"
            | "tool.progress"
            | "tool.completed"
            | "tool.failed"
            | "clarify.request"
            | "clarify.resolve"
            | "clarify.cancel"
            | "clarify.requested"
            | "clarify.responded"
            | "approval.request"
            | "approval.resolve"
            | "approval.cancel"
            | "approval.requested"
            | "approval.responded"
            | "session.start"
            | "session.update"
            | "session.complete"
            | "session.cancel"
            | "session.error"
            | "session.started"
            | "session.resumed"
            | "session.ended"
            | "command.requested"
            | "command.accepted"
            | "command.progress"
            | "command.completed"
            | "command.failed"
            | "command.cancelled"
            | "artifact.started"
            | "artifact.progress"
            | "artifact.completed"
            | "artifact.created"
            | "artifact.ready"
            | "artifact.failed"
    )
}

fn validate_artifact(artifact: &GatewayArtifact) -> Result<(), ProtocolError> {
    validate_text(&artifact.id)?;
    validate_text(&artifact.kind)?;
    if let Some(name) = &artifact.name {
        validate_text(name)?;
    }
    if let Some(mime_type) = &artifact.mime_type {
        validate_text(mime_type)?;
        let mime_type = mime_type.to_ascii_lowercase();
        if mime_type.starts_with("audio/") || mime_type.starts_with("video/") {
            return Err(ProtocolError::InvalidMessage);
        }
    }
    if artifact.size.is_some_and(|size| size < 0) {
        return Err(ProtocolError::InvalidMessage);
    }
    if let Some(uri) = &artifact.uri {
        validate_text(uri)?;
    }
    if let Some(download_url) = &artifact.download_url {
        validate_text(download_url)?;
    }
    if let Some(sha256) = &artifact.sha256 {
        validate_text(sha256)?;
    }
    Ok(())
}

pub fn error_for(error: &ProtocolError, reply_to: Option<String>) -> GatewayMessage {
    let code = match error {
        ProtocolError::UnknownType(_) => "UNKNOWN_TYPE",
        ProtocolError::UnsupportedVersion(_) => "UNSUPPORTED_VERSION",
        ProtocolError::InvalidDeviceId => "INVALID_DEVICE_ID",
        _ => "INVALID_MESSAGE",
    };
    GatewayMessage::Error {
        version: PROTOCOL_VERSION,
        code: code.to_owned(),
        message: error.to_string(),
        reply_to,
    }
}

pub fn ack(message_id: impl Into<String>) -> GatewayMessage {
    GatewayMessage::MessageAck {
        version: PROTOCOL_VERSION,
        message_id: message_id.into(),
        status: "received".into(),
    }
}

pub fn agent_ack(
    event_id: impl Into<String>,
    seq: u64,
    status: impl Into<String>,
    expected_seq: Option<u64>,
) -> GatewayMessage {
    GatewayMessage::AgentAck {
        version: PROTOCOL_VERSION,
        event_id: event_id.into(),
        seq,
        status: status.into(),
        expected_seq,
    }
}

/// Frame types the Python helper can send that sit outside the typed
/// [GatewayMessage] enum. They carry no `event_id`/`seq`, so they are not
/// sequenced agent events — they are forwarded to mobile as notifications.
pub const EXTENSION_TYPES: &[&str] = &[
    "delivery.send",
    "delivery.ack",
    "cron.delivery",
    "proactive.delivery",
    "command.request",
    "slash.command",
    "command.reply",
    "slash.reply",
    "artifact",
    "artifact.event",
    "session.open",
    "session.close",
    "session.reset",
    "session.list",
    "session.info",
    "session.reply",
    "typing",
    "typing.start",
    "typing.stop",
    "stream.start",
    "stream.delta",
    "stream.end",
    "agent.state",
    "tool.state",
];

pub fn is_extension_type(message_type: &str) -> bool {
    EXTENSION_TYPES.contains(&message_type)
}

/// A minimally validated extension frame kept as raw JSON.
#[derive(Debug, Clone)]
pub struct ExtensionFrame {
    pub message_type: String,
    pub raw: Value,
}

pub fn parse_extension(input: &str) -> Result<ExtensionFrame, ProtocolError> {
    let value: Value = serde_json::from_str(input).map_err(|_| ProtocolError::InvalidJson)?;
    let object = value.as_object().ok_or(ProtocolError::InvalidEnvelope)?;
    let version = object
        .get("version")
        .and_then(Value::as_u64)
        .and_then(|value| u32::try_from(value).ok())
        .ok_or(ProtocolError::InvalidMessage)?;
    if version != PROTOCOL_VERSION {
        return Err(ProtocolError::UnsupportedVersion(version));
    }
    let message_type = object
        .get("type")
        .and_then(Value::as_str)
        .ok_or(ProtocolError::MissingType)?;
    if !is_extension_type(message_type) {
        return Err(ProtocolError::UnknownType(message_type.to_owned()));
    }
    validate_extension(message_type, &value)?;
    Ok(ExtensionFrame {
        message_type: message_type.to_owned(),
        raw: value,
    })
}

fn require_extension_text(value: &Value, field: &str) -> Result<(), ProtocolError> {
    match value.get(field).and_then(Value::as_str) {
        Some(text) if !text.trim().is_empty() => Ok(()),
        _ => Err(ProtocolError::InvalidMessage),
    }
}

fn validate_extension(message_type: &str, value: &Value) -> Result<(), ProtocolError> {
    match message_type {
        "delivery.send" | "cron.delivery" | "proactive.delivery" => {
            require_extension_text(value, "delivery_id")?;
            require_extension_text(value, "conversation_id")?;
            let has_content = value
                .get("content")
                .and_then(Value::as_str)
                .is_some_and(|text| !text.trim().is_empty());
            let has_attachments = value
                .get("attachments")
                .and_then(Value::as_array)
                .is_some_and(|items| !items.is_empty());
            if !has_content && !has_attachments {
                return Err(ProtocolError::InvalidMessage);
            }
            if let Some(mime) = value
                .get("attachments")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|item| item.get("mime_type").and_then(Value::as_str))
                .next()
            {
                let mime = mime.to_ascii_lowercase();
                if mime.starts_with("audio/") || mime.starts_with("video/") {
                    return Err(ProtocolError::InvalidMessage);
                }
            }
        }
        "delivery.ack" => {
            require_extension_text(value, "delivery_id")?;
            require_extension_text(value, "status")?;
        }
        "command.request" | "slash.command" => {
            require_extension_text(value, "request_id")?;
            require_extension_text(value, "conversation_id")?;
            require_extension_text(value, "command")?;
        }
        "command.reply" | "slash.reply" => {
            require_extension_text(value, "request_id")?;
            require_extension_text(value, "status")?;
        }
        "artifact" | "artifact.event" => {
            for field in ["artifact_id", "conversation_id", "name", "mime_type"] {
                require_extension_text(value, field)?;
            }
            let mime = value
                .get("mime_type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_ascii_lowercase();
            if mime.starts_with("audio/") || mime.starts_with("video/") {
                return Err(ProtocolError::InvalidMessage);
            }
            let has_uri = ["url", "download_url", "content"].into_iter().any(|field| {
                value
                    .get(field)
                    .and_then(Value::as_str)
                    .is_some_and(|text| !text.trim().is_empty())
            });
            if !has_uri {
                return Err(ProtocolError::InvalidMessage);
            }
        }
        "session.open" => {
            require_extension_text(value, "request_id")?;
            require_extension_text(value, "conversation_id")?;
        }
        "session.close" | "session.reset" | "session.info" | "session.reply" => {
            require_extension_text(value, "request_id")?;
        }
        "session.list" => {
            require_extension_text(value, "request_id")?;
        }
        "typing" | "typing.start" | "typing.stop" => {
            require_extension_text(value, "conversation_id")?;
            if let Some(state) = value.get("state").and_then(Value::as_str) {
                if !matches!(state, "start" | "stop" | "started" | "stopped") {
                    return Err(ProtocolError::InvalidMessage);
                }
            }
        }
        "stream.start" | "stream.delta" | "stream.end" => {
            require_extension_text(value, "stream_id")?;
        }
        "agent.state" => {
            require_extension_text(value, "conversation_id")?;
            require_extension_text(value, "state")?;
        }
        "tool.state" => {
            require_extension_text(value, "conversation_id")?;
            require_extension_text(value, "tool_call_id")?;
            require_extension_text(value, "state")?;
        }
        _ => return Err(ProtocolError::UnknownType(message_type.to_owned())),
    }
    Ok(())
}

/// Builds the `delivery.ack` frame the plugin waiter expects.
pub fn delivery_ack(delivery_id: &str, status: &str, conversation_id: Option<&str>) -> Value {
    let mut payload = serde_json::json!({
        "version": PROTOCOL_VERSION,
        "type": "delivery.ack",
        "delivery_id": delivery_id,
        "status": status,
    });
    if let Some(conversation_id) = conversation_id {
        payload["conversation_id"] = Value::String(conversation_id.to_owned());
    }
    payload
}

/// Maps an extension frame onto one or more mobile `event` payloads.
///
/// The mobile client already renders these kinds; unknown shapes degrade to
/// an empty list so the caller can skip the notification safely.
pub fn extension_mobile_events(frame: &ExtensionFrame) -> Vec<Value> {
    let raw = &frame.raw;
    match frame.message_type.as_str() {
        "delivery.send" | "cron.delivery" | "proactive.delivery" => {
            vec![serde_json::json!({
                "kind": "delivery.notification",
                "messageId": raw["delivery_id"],
                "message": raw["content"],
                "ok": true,
                "conversationId": raw["conversation_id"],
            })]
        }
        "delivery.ack" => {
            let status = raw["status"].as_str().unwrap_or_default();
            vec![serde_json::json!({
                "kind": "delivery.notification.result",
                "messageId": raw["delivery_id"],
                "ok": matches!(status, "received" | "resolved" | "duplicate"),
            })]
        }
        "command.request" | "slash.command" => {
            let command = raw["command"].as_str().unwrap_or_default();
            vec![serde_json::json!({
                "kind": "delivery.notification",
                "messageId": raw["request_id"],
                "message": format!("命令请求：{command}"),
                "ok": true,
                "conversationId": raw["conversation_id"],
            })]
        }
        "command.reply" | "slash.reply" => {
            let status = raw["status"].as_str().unwrap_or("completed");
            vec![serde_json::json!({
                "kind": "hermes.command.result",
                "id": raw["request_id"],
                "command": raw["command"],
                "status": status,
                "content": raw["content"].as_str().or_else(|| raw["choice"].as_str()).unwrap_or_default(),
            })]
        }
        "artifact" | "artifact.event" => {
            vec![serde_json::json!({
                "kind": "artifact.completed",
                "artifactId": raw["artifact_id"],
                "name": raw["name"],
                "mimeType": raw["mime_type"],
                "url": raw["download_url"].as_str().or_else(|| raw["url"].as_str()).unwrap_or_default(),
                "size": raw["size"],
                "conversationId": raw["conversation_id"],
            })]
        }
        "session.open" | "session.close" | "session.reset" | "session.list" | "session.info"
        | "session.reply" => {
            let status = raw["status"].as_str().unwrap_or("completed");
            vec![serde_json::json!({
                "kind": "session.status",
                "id": raw["session_id"].as_str().or_else(|| raw["request_id"].as_str()).unwrap_or_default(),
                "event": frame.message_type,
                "status": status,
                "message": raw["content"],
            })]
        }
        "typing" | "typing.start" | "typing.stop" => {
            let state = raw["state"].as_str().unwrap_or("");
            let active =
                if frame.message_type.ends_with("stop") || state == "stop" || state == "stopped" {
                    false
                } else {
                    true
                };
            vec![serde_json::json!({
                "kind": "agent.typing",
                "active": active,
                "typing": active,
                "conversationId": raw["conversation_id"],
            })]
        }
        "stream.start" => {
            vec![serde_json::json!({
                "kind": "agent.start",
                "streamId": raw["stream_id"],
                "runId": raw["run_id"].as_str().or_else(|| raw["stream_id"].as_str()).unwrap_or_default(),
                "conversationId": raw["conversation_id"],
            })]
        }
        "stream.delta" => {
            vec![serde_json::json!({
                "kind": "agent.delta",
                "streamId": raw["stream_id"],
                "runId": raw["stream_id"],
                "delta": raw["delta"],
                "sequence": raw["sequence"],
                "conversationId": raw["conversation_id"],
            })]
        }
        "stream.end" => {
            let status = raw["status"].as_str().unwrap_or("completed");
            let kind = if status == "failed" {
                "agent.error"
            } else {
                "agent.complete"
            };
            vec![serde_json::json!({
                "kind": kind,
                "streamId": raw["stream_id"],
                "runId": raw["stream_id"],
                "conversationId": raw["conversation_id"],
            })]
        }
        "agent.state" => {
            vec![serde_json::json!({
                "kind": "agent.status",
                "status": raw["state"],
                "message": raw["message"],
                "conversationId": raw["conversation_id"],
            })]
        }
        "tool.state" => {
            vec![serde_json::json!({
                "kind": "tool.update",
                "toolCallId": raw["tool_call_id"],
                "name": raw["tool_name"],
                "status": raw["state"],
                "detail": raw["message"],
                "conversationId": raw["conversation_id"],
            })]
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_utf8_message_send() {
        let message = parse_message(
            r#"{"version":1,"type":"message.send","message_id":"msg_001","conversation_id":"conv_001","content":"你好 Hermes"}"#,
        )
        .unwrap();
        assert_eq!(
            message,
            GatewayMessage::MessageSend {
                version: 1,
                message_id: "msg_001".into(),
                conversation_id: "conv_001".into(),
                content: "你好 Hermes".into(),
                attachments: vec![],
            }
        );
    }

    #[test]
    fn agent_device_ids_follow_the_owner_device_agent_convention() {
        assert!(is_valid_agent_device_id("JXCZ_MBA_Hermes"));
        assert!(is_valid_agent_device_id("JXCZ_WIN_Hermes"));
        assert!(is_valid_agent_device_id("jxcZ_mba_hermes"));
        assert!(!is_valid_agent_device_id("orialis-hermes-macbook"));
        assert!(!is_valid_agent_device_id("JXCZ_MBA_Hermes_Extra"));
    }

    #[test]
    fn rejects_missing_field_without_panicking() {
        let error = parse_message(r#"{"version":1,"type":"message.send"}"#).unwrap_err();
        assert_eq!(error, ProtocolError::InvalidMessage);
    }

    #[test]
    fn rejects_blank_content() {
        let error = parse_message(
            r#"{"version":1,"type":"message.send","message_id":"msg_1","conversation_id":"conv_1","content":"  "}"#,
        )
        .unwrap_err();
        assert_eq!(error, ProtocolError::InvalidMessage);
    }

    #[test]
    fn attachment_only_messages_are_valid_and_keep_structured_metadata() {
        let message = parse_message(
            r#"{"version":1,"type":"message.send","message_id":"msg_1","conversation_id":"conv_1","content":"","attachments":[{"id":"att_1","name":"note.txt","mime_type":"text/plain","size":4,"download_url":"https://example.test/api/v1/attachments/att_1/download"}]}"#,
        )
        .unwrap();
        assert!(
            matches!(message, GatewayMessage::MessageSend { attachments, .. } if attachments.len() == 1)
        );
    }

    #[test]
    fn rejects_unknown_type_as_protocol_error() {
        let error = parse_message(r#"{"version":1,"type":"future.event"}"#).unwrap_err();
        assert_eq!(error, ProtocolError::UnknownType("future.event".into()));
    }

    #[test]
    fn rejects_wrong_version() {
        let error = parse_message(r#"{"version":2,"type":"ping"}"#).unwrap_err();
        assert_eq!(error, ProtocolError::UnsupportedVersion(2));
    }

    #[test]
    fn parses_message_ack() {
        assert_eq!(
            parse_message(
                r#"{"version":1,"type":"message.ack","message_id":"msg_1","status":"received"}"#
            )
            .unwrap(),
            GatewayMessage::MessageAck {
                version: 1,
                message_id: "msg_1".into(),
                status: "received".into(),
            }
        );
    }

    #[test]
    fn parses_mobile_envelope_and_preserves_request_id() {
        let envelope = parse_mobile_envelope(
            r#"{"version":1,"type":"event","request_id":"req_1","payload":{"id":"evt_1"}}"#,
        )
        .unwrap();
        assert_eq!(envelope.message_type, MOBILE_EVENT);
        assert_eq!(envelope.request_id.as_deref(), Some("req_1"));
        assert_eq!(envelope.payload["id"], "evt_1");
    }

    #[test]
    fn mobile_change_hint_uses_common_envelope() {
        let value = serde_json::to_value(mobile_sync_change_hint(42, Some("task"))).unwrap();
        assert_eq!(value["type"], MOBILE_SYNC_CHANGE_HINT);
        assert_eq!(
            value["payload"],
            serde_json::json!({"cursor": 42, "entity": "task"})
        );
    }

    #[test]
    fn rejects_mobile_non_object_payload() {
        let error =
            parse_mobile_envelope(r#"{"version":1,"type":"ping","payload":[]}"#).unwrap_err();
        assert_eq!(error, ProtocolError::InvalidMessage);
    }

    #[test]
    fn mobile_envelope_round_trips_optional_request_id() {
        let original = mobile_envelope(
            MOBILE_MESSAGE,
            Some("request-42".into()),
            serde_json::json!({"message_id": "msg-1", "content": "你好"}),
        );
        let wire = serde_json::to_string(&original).unwrap();
        assert_eq!(parse_mobile_envelope(&wire).unwrap(), original);
    }

    #[test]
    fn rejects_mobile_malformed_and_non_object_envelopes() {
        assert_eq!(
            parse_mobile_envelope("not-json").unwrap_err(),
            ProtocolError::InvalidJson
        );
        assert_eq!(
            parse_mobile_envelope("[]").unwrap_err(),
            ProtocolError::InvalidJson
        );
    }

    #[test]
    fn rejects_mobile_missing_required_envelope_fields() {
        for wire in [
            r#"{"type":"ping","payload":{}}"#,
            r#"{"version":1,"payload":{}}"#,
            r#"{"version":1,"type":"ping"}"#,
        ] {
            assert_eq!(
                parse_mobile_envelope(wire).unwrap_err(),
                ProtocolError::InvalidJson
            );
        }
    }

    #[test]
    fn rejects_mobile_unknown_type_and_unsupported_version() {
        assert_eq!(
            parse_mobile_envelope(r#"{"version":1,"type":"future.event","payload":{}}"#)
                .unwrap_err(),
            ProtocolError::UnknownType("future.event".into())
        );
        assert_eq!(
            parse_mobile_envelope(r#"{"version":2,"type":"ping","payload":{}}"#).unwrap_err(),
            ProtocolError::UnsupportedVersion(2)
        );
    }

    #[test]
    fn hermes_message_wire_shape_still_round_trips() {
        let original = GatewayMessage::MessageSend {
            version: PROTOCOL_VERSION,
            message_id: "msg-1".into(),
            conversation_id: "conv-1".into(),
            content: "hello Hermes".into(),
            attachments: vec![],
        };
        let wire = serde_json::to_string(&original).unwrap();
        assert_eq!(parse_message(&wire).unwrap(), original);
    }

    #[test]
    fn structured_agent_event_round_trips_with_sequence_and_artifact() {
        let original = GatewayMessage::AgentComplete {
            version: PROTOCOL_VERSION,
            event_id: "evt-1".into(),
            seq: 7,
            session_id: "session-1".into(),
            run_id: "run-1".into(),
            content: "done".into(),
            artifacts: vec![GatewayArtifact {
                id: "artifact-1".into(),
                kind: "document".into(),
                name: Some("result.txt".into()),
                mime_type: Some("text/plain".into()),
                size: Some(4),
                uri: Some("https://example.test/artifacts/1".into()),
                download_url: None,
                sha256: None,
                metadata: Some(serde_json::json!({"source": "hermes"})),
            }],
        };
        let wire = serde_json::to_string(&original).unwrap();
        assert_eq!(parse_message(&wire).unwrap(), original);
        assert_eq!(serde_json::from_str::<Value>(&wire).unwrap()["seq"], 7);
    }

    #[test]
    fn generic_event_envelope_accepts_registered_non_voice_event_types() {
        let message = parse_message(
            r#"{"version":1,"type":"event","event_id":"evt-1","event_type":"artifact.ready","sequence":15,"occurred_at":"2026-09-17T08:00:03Z","session_id":"sess-1","correlation_id":"cmd-1","payload":{"artifact_id":"art-1","kind":"document","name":"report.pdf","mime_type":"application/pdf","size":12,"download_url":"https://example.test/report.pdf"}}"#,
        )
        .unwrap();
        assert!(matches!(
            message,
            GatewayMessage::Event { sequence: 15, .. }
        ));
        let wire = serde_json::to_string(&message).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&wire).unwrap()["type"],
            "event"
        );
    }

    #[test]
    fn generic_event_rejects_unknown_or_voice_event_payloads() {
        let unknown = parse_message(
            r#"{"version":1,"type":"event","event_id":"evt-1","event_type":"future.event","sequence":1,"occurred_at":"2026-09-17T08:00:00Z","payload":{}}"#,
        )
        .unwrap_err();
        assert_eq!(unknown, ProtocolError::UnknownType("future.event".into()));
        let voice = parse_message(
            r#"{"version":1,"type":"event","event_id":"evt-2","event_type":"artifact.ready","sequence":1,"occurred_at":"2026-09-17T08:00:00Z","payload":{"mime_type":"audio/mpeg"}}"#,
        )
        .unwrap_err();
        assert_eq!(voice, ProtocolError::InvalidMessage);
    }

    #[test]
    fn capabilities_resume_and_approval_decisions_are_wire_compatible() {
        let capabilities = parse_message(
            r#"{"version":1,"type":"capabilities.hello","capabilities":["agent.delta"],"resume_from":12}"#,
        )
        .unwrap();
        assert!(matches!(
            capabilities,
            GatewayMessage::CapabilitiesHello {
                resume_from: Some(12),
                ..
            }
        ));
        let approval = parse_message(
            r#"{"version":1,"type":"approval.resolve","event_id":"evt-2","seq":2,"session_id":"session-1","request_id":"approval-1","decision":"always"}"#,
        )
        .unwrap();
        assert!(matches!(
            approval,
            GatewayMessage::ApprovalResolve {
                decision: ApprovalDecision::Always,
                ..
            }
        ));
    }

    #[test]
    fn event_sequence_and_structured_fields_are_validated() {
        assert_eq!(
            parse_message(
                r#"{"version":1,"type":"agent.delta","event_id":"evt-1","seq":0,"session_id":"session-1","run_id":"run-1","delta":"x"}"#,
            )
            .unwrap_err(),
            ProtocolError::InvalidMessage
        );
        assert_eq!(
            parse_message(
                r#"{"version":1,"type":"approval.resolve","event_id":"evt-1","seq":1,"session_id":"session-1","request_id":"approval-1","decision":"later"}"#,
            )
            .unwrap_err(),
            ProtocolError::InvalidMessage
        );
    }
}
