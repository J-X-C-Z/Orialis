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
    },
    #[serde(rename = "message.reply")]
    MessageReply {
        version: u32,
        message_id: String,
        reply_to: String,
        conversation_id: String,
        content: String,
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
            ..
        } => {
            for value in [message_id, conversation_id, content] {
                validate_text(value)?;
            }
        }
        GatewayMessage::MessageReply {
            message_id,
            reply_to,
            conversation_id,
            content,
            ..
        } => {
            for value in [message_id, reply_to, conversation_id, content] {
                validate_text(value)?;
            }
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
        GatewayMessage::HelloAck { .. }
        | GatewayMessage::Ping { .. }
        | GatewayMessage::Pong { .. } => {}
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
        };
        let wire = serde_json::to_string(&original).unwrap();
        assert_eq!(parse_message(&wire).unwrap(), original);
    }
}
