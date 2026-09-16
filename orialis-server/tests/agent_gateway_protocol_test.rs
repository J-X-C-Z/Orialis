#[path = "../src/agent_gateway/protocol.rs"]
mod protocol;

use protocol::{
    parse_message, parse_mobile_envelope, GatewayMessage, ProtocolError, MOBILE_MESSAGE,
    PROTOCOL_VERSION,
};

#[test]
fn mobile_envelope_accepts_request_id_and_object_payload() {
    let envelope = parse_mobile_envelope(
        r#"{"version":1,"type":"message","request_id":"req-1","payload":{"id":"msg-1"}}"#,
    )
    .unwrap();

    assert_eq!(envelope.version, PROTOCOL_VERSION);
    assert_eq!(envelope.message_type, MOBILE_MESSAGE);
    assert_eq!(envelope.request_id.as_deref(), Some("req-1"));
    assert_eq!(envelope.payload["id"], "msg-1");
}

#[test]
fn mobile_envelope_rejects_invalid_shapes_and_types() {
    for wire in [
        "not-json",
        "[]",
        r#"{"version":1,"type":"message"}"#,
        r#"{"version":1,"payload":{}}"#,
        r#"{"version":1,"type":"message","payload":[]}"#,
    ] {
        assert!(matches!(
            parse_mobile_envelope(wire),
            Err(ProtocolError::InvalidJson | ProtocolError::InvalidMessage)
        ));
    }

    assert_eq!(
        parse_mobile_envelope(r#"{"version":1,"type":"not-supported","payload":{}}"#,).unwrap_err(),
        ProtocolError::UnknownType("not-supported".into())
    );
    assert_eq!(
        parse_mobile_envelope(r#"{"version":99,"type":"ping","payload":{}}"#).unwrap_err(),
        ProtocolError::UnsupportedVersion(99)
    );
}

#[test]
fn hermes_legacy_message_shape_still_round_trips() {
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
