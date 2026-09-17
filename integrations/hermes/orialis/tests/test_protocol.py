import json
import unittest
from pathlib import Path

from .. import protocol


EXAMPLES = Path(__file__).resolve().parents[4] / "protocol" / "agent-gateway" / "examples"
CONTRACT_FIXTURES = Path(__file__).resolve().parents[4] / "protocol" / "contracts" / "fixtures"
PLUGIN_FIXTURES = Path(__file__).resolve().parent / "fixtures"


class ProtocolTests(unittest.TestCase):
    def test_agent_device_id_convention(self):
        from ..protocol import is_valid_agent_device_id

        self.assertTrue(is_valid_agent_device_id("JXCZ_MBA_Hermes"))
        self.assertTrue(is_valid_agent_device_id("JXCZ_WIN_Hermes"))
        self.assertTrue(is_valid_agent_device_id("jxcZ_mba_hermes"))
        self.assertFalse(is_valid_agent_device_id("orialis-hermes-macbook"))

    def test_shared_examples_are_valid(self):
        for name in (
            "hello", "hello_ack", "ping", "pong", "message_send", "message_reply", "message_ack", "error"
        ):
            with self.subTest(name=name):
                payload = json.loads((EXAMPLES / f"{name}.json").read_text(encoding="utf-8"))
                self.assertEqual(protocol.parse_message(payload)["version"], 1)

    def test_unknown_type_is_a_protocol_error(self):
        with self.assertRaisesRegex(protocol.ProtocolError, "unknown message type"):
            protocol.parse_message({"version": 1, "type": "future.event"})

    def test_chinese_text_round_trips_without_ascii_escaping(self):
        encoded = protocol.encode(protocol.reply(
            message_id="msg_2", reply_to="msg_1", conversation_id="conv_1", content="你好 Hermes"
        ))
        self.assertIn("你好 Hermes", encoded)
        self.assertEqual(protocol.parse_message(encoded)["content"], "你好 Hermes")

    def test_message_ack_is_valid(self):
        message = protocol.ack("msg_001")
        self.assertEqual(protocol.parse_message(message), message)

    def test_agent_ack_is_valid(self):
        message = protocol.parse_message({
            "version": 1,
            "type": "agent.ack",
            "event_id": "evt_001",
            "seq": 3,
            "status": "received",
        })
        self.assertEqual(message["event_id"], "evt_001")
        self.assertEqual(message["seq"], 3)

    def test_agent_ack_payload_status_and_gap_are_validated(self):
        for fixture_name in ("agent_ack_received.json", "agent_ack_gap.json"):
            with self.subTest(fixture_name=fixture_name):
                message = json.loads((PLUGIN_FIXTURES / fixture_name).read_text(encoding="utf-8"))
                self.assertEqual(protocol.parse_message(message)["type"], "agent.ack")
        with self.assertRaisesRegex(protocol.ProtocolError, "status is invalid"):
            protocol.parse_message({"version": 1, "type": "agent.ack", "event_id": "e", "seq": 1, "status": "done"})
        with self.assertRaisesRegex(protocol.ProtocolError, "requires a positive expected_seq"):
            protocol.parse_message({"version": 1, "type": "agent.ack", "event_id": "e", "seq": 1, "status": "gap"})

    def test_request_and_tombstone_fixtures_keep_ack_and_entity_semantics_separate(self):
        request = json.loads((PLUGIN_FIXTURES / "message_send_request.json").read_text(encoding="utf-8"))
        self.assertEqual(protocol.parse_message(request)["type"], "message.send")
        tombstone = json.loads((PLUGIN_FIXTURES / "task_tombstone.json").read_text(encoding="utf-8"))
        parsed = protocol.validate_domain_record("task", tombstone)
        self.assertIsNotNone(parsed["deletedAt"])
        self.assertEqual(protocol.parse_message(protocol.ack("msg-request"))["type"], "message.ack")

    def test_structured_attachments_are_valid_and_audio_video_are_rejected(self):
        attachment = {
            "id": "att_1", "name": "a.png", "mime_type": "image/png",
            "size": 12, "download_url": "https://orialis.test/a",
        }
        parsed = protocol.parse_message({
            "version": 1, "type": "message.send", "message_id": "m",
            "conversation_id": "c", "content": "look", "attachments": [attachment],
        })
        self.assertEqual(parsed["attachments"][0]["id"], "att_1")
        for mime in ("audio/ogg", "video/mp4"):
            with self.subTest(mime=mime), self.assertRaises(protocol.ProtocolError):
                protocol.parse_message({
                    "version": 1, "type": "message.reply", "message_id": "m",
                    "reply_to": "r", "conversation_id": "c", "content": "x",
                    "attachments": [{**attachment, "mime_type": mime}],
                })

    def test_attachment_only_messages_and_server_camel_case_metadata_are_normalized(self):
        parsed = protocol.parse_message({
            "version": 1, "type": "message.send", "message_id": "m",
            "conversation_id": "c", "content": "",
            "attachments": [{
                "id": "att_1", "name": "report.pdf", "mimeType": "application/pdf",
                "size": 3, "downloadUrl": "https://orialis.test/a",
            }],
        })
        self.assertEqual(parsed["attachments"][0]["mime_type"], "application/pdf")
        self.assertNotIn("mimeType", parsed["attachments"][0])

    def test_attachment_rejects_inline_bytes_and_unknown_fields(self):
        with self.assertRaisesRegex(protocol.ProtocolError, "metadata only"):
            protocol.parse_message({
                "version": 1, "type": "message.send", "message_id": "m",
                "conversation_id": "c", "content": "x", "attachments": [{
                    "id": "a", "name": "x.txt", "mime_type": "text/plain",
                    "size": 1, "download_url": "https://orialis.test/a", "data": "base64",
                }],
            })

    def test_task_and_schedule_fixtures_follow_shared_v1_contract(self):
        for kind in ("task", "schedule"):
            with self.subTest(kind=kind):
                fixture_name = "task-unclassified.json" if kind == "task" else "schedule-v1.json"
                record = json.loads((CONTRACT_FIXTURES / fixture_name).read_text(encoding="utf-8"))
                self.assertEqual(protocol.validate_domain_record(kind, record), record)

    def test_task_priority_is_tristate_and_recurrence_is_not_arbitrary_json(self):
        task = json.loads((CONTRACT_FIXTURES / "task-unclassified.json").read_text(encoding="utf-8"))
        for value in (None, False, True):
            with self.subTest(value=value):
                candidate = {**task, "important": value, "urgent": value}
                self.assertEqual(protocol.validate_domain_record("task", candidate), candidate)
        for field in ("important", "urgent"):
            with self.subTest(field=field), self.assertRaisesRegex(protocol.ProtocolError, "boolean or null"):
                protocol.validate_domain_record("task", {**task, field: "false"})
        recurrence = {"rule": "FREQ=DAILY", "until": "2026-12-31"}
        self.assertEqual(
            protocol.validate_domain_record("task", {**task, "recurrence": recurrence})["recurrence"],
            recurrence,
        )
        for invalid in ("nonsense", {"rule": "FREQ=DAILY"}, {"rule": "FREQ=DAILY", "until": "2026-12-31", "extra": 1}, {"rule": "FREQ=DAILY", "until": "2026-02-30"}):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(protocol.ProtocolError, "recurrence"):
                protocol.validate_domain_record("task", {**task, "recurrence": invalid})
        with self.assertRaisesRegex(protocol.ProtocolError, "valid YYYY-MM-DD"):
            protocol.validate_domain_record("task", {**task, "due": "2026-02-30"})
        with self.assertRaisesRegex(protocol.ProtocolError, "required"):
            protocol.validate_domain_record("task", {key: value for key, value in task.items() if key != "important"})
        with self.assertRaisesRegex(protocol.ProtocolError, "requires task.due"):
            protocol.validate_domain_record("task", {**task, "due": None, "dueTime": "23:59"})

    def test_schedule_has_exact_public_fields_and_calendar_event_is_only_wire_compatibility(self):
        schedule = json.loads((CONTRACT_FIXTURES / "schedule-v1.json").read_text(encoding="utf-8"))
        self.assertEqual(
            set(schedule),
            {"id", "title", "description", "location", "startAt", "endAt", "allDay",
             "reminderMinutes", "createdAt", "updatedAt", "version", "deletedAt"},
        )
        for deferred_field in ("taskId", "projectId", "source", "externalId"):
            with self.subTest(field=deferred_field), self.assertRaisesRegex(protocol.ProtocolError, "unsupported fields"):
                protocol.validate_domain_record("schedule", {**schedule, deferred_field: "not-v1"})
        with self.assertRaisesRegex(protocol.ProtocolError, "unsupported domain kind"):
            protocol.validate_domain_record("calendar_event", schedule)
