#[path = "../src/agent_gateway/protocol.rs"]
mod protocol;

use protocol::{
    delivery_ack, extension_mobile_events, is_extension_type, parse_extension, parse_message,
    parse_mobile_envelope, GatewayMessage, ProtocolError, MOBILE_MESSAGE, PROTOCOL_VERSION,
};
use serde_json::Value;

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

#[test]
fn sync_contract_fixtures_preserve_versions_and_tombstones() {
    let mutation: Value = serde_json::from_str(include_str!(
        "../../protocol/contracts/fixtures/mutation-request-v1.json"
    ))
    .unwrap();
    let event: Value = serde_json::from_str(include_str!(
        "../../protocol/contracts/fixtures/sync-event-tombstone-v1.json"
    ))
    .unwrap();

    assert_eq!(mutation["mutationId"], "mobile-mutation-42");
    assert_eq!(mutation["baseVersion"], 2);
    assert_eq!(mutation["entityVersion"], 3);
    assert_eq!(event["entityVersion"], 3);
    assert_eq!(event["tombstone"], true);
    assert_eq!(event["payload"], Value::Null);
}

#[test]
fn extension_types_are_accepted_and_mapped_to_mobile_notifications() {
    for wire in [
        r#"{"version":1,"type":"proactive.delivery","delivery_id":"d1","conversation_id":"c1","content":"定时提醒：喝水"}"#,
        r#"{"version":1,"type":"cron.delivery","delivery_id":"d2","conversation_id":"c1","content":"整点报时"}"#,
        r#"{"version":1,"type":"delivery.send","delivery_id":"d3","conversation_id":"c1","content":"主动通知"}"#,
        r#"{"version":1,"type":"command.request","request_id":"r1","conversation_id":"c1","command":"/status"}"#,
        r#"{"version":1,"type":"artifact","artifact_id":"a1","conversation_id":"c1","name":"report.pdf","mime_type":"application/pdf","download_url":"https://example.test/r.pdf"}"#,
        r#"{"version":1,"type":"session.open","request_id":"r2","conversation_id":"c1"}"#,
        r#"{"version":1,"type":"stream.delta","stream_id":"s1","delta":"hello","sequence":1,"conversation_id":"c1"}"#,
    ] {
        let frame = parse_extension(wire).unwrap();
        assert!(is_extension_type(&frame.message_type));
        let events = extension_mobile_events(&frame);
        assert!(
            !events.is_empty(),
            "no mobile event for {}",
            frame.message_type
        );
        assert_eq!(events[0]["kind"].as_str().is_some(), true);
    }
}

#[test]
fn proactive_delivery_maps_to_delivery_notification_and_ack() {
    let frame = parse_extension(
        r#"{"version":1,"type":"proactive.delivery","delivery_id":"d1","conversation_id":"c1","content":"定时提醒：喝水"}"#,
    )
    .unwrap();
    let events = extension_mobile_events(&frame);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0]["kind"], "delivery.notification");
    assert_eq!(events[0]["message"], "定时提醒：喝水");
    assert_eq!(events[0]["messageId"], "d1");

    let ack = delivery_ack("d1", "received", Some("c1"));
    assert_eq!(ack["type"], "delivery.ack");
    assert_eq!(ack["delivery_id"], "d1");
    assert_eq!(ack["status"], "received");
    assert_eq!(ack["conversation_id"], "c1");
}

#[test]
fn clarify_request_accepts_gateway_choices_alias() {
    let message = parse_message(
        r#"{"version":1,"type":"clarify.request","event_id":"evt-1","seq":1,"session_id":"s1","request_id":"c1","question":"选择项目","choices":["Orialis","其他"]}"#,
    )
    .unwrap();
    match message {
        GatewayMessage::ClarifyRequest {
            options, question, ..
        } => {
            assert_eq!(question, "选择项目");
            assert_eq!(options.len(), 2);
        }
        other => panic!("unexpected frame: {other:?}"),
    }
}

#[test]
fn extension_frames_reject_invalid_shapes() {
    for wire in [
        r#"{"version":1,"type":"proactive.delivery","delivery_id":"d1"}"#,
        r#"{"version":1,"type":"proactive.delivery","delivery_id":"d1","conversation_id":"c1"}"#,
        r#"{"version":1,"type":"artifact","artifact_id":"a1","conversation_id":"c1","name":"x","mime_type":"audio/mpeg","download_url":"https://example.test/a"}"#,
        r#"{"version":99,"type":"stream.delta","stream_id":"s1","delta":"x"}"#,
    ] {
        assert!(parse_extension(wire).is_err(), "should reject {wire}");
    }
    assert_eq!(
        parse_extension(r#"{"version":1,"type":"not-an-extension","foo":1}"#).unwrap_err(),
        ProtocolError::UnknownType("not-an-extension".into())
    );
}
