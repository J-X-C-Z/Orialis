// Exact unmodified excerpts from Orialis f9a064bf05b18265afd26905e7240777d4ce355c.
// See orialis_delivery_mapper_provenance.json; only module imports are added.
use serde_json::Value;
use std::fmt;

pub const PROTOCOL_VERSION: u32 = 1;

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
                !(frame.message_type.ends_with("stop") || state == "stop" || state == "stopped");
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
