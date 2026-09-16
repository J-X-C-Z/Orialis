import json
import unittest
from pathlib import Path

from .. import protocol


EXAMPLES = Path(__file__).resolve().parents[4] / "protocol" / "agent-gateway" / "examples"


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

    def test_future_domain_contracts_keep_task_and_schedule_distinct(self):
        task = {"id": "t", "title": "Do", "createdAt": "1", "updatedAt": "2", "version": 1}
        schedule = {"id": "s", "title": "Meet", "startAt": "2", "endAt": "3",
                    "createdAt": "1", "updatedAt": "2", "version": 1}
        self.assertEqual(protocol.validate_domain_record("task", task), task)
        self.assertEqual(protocol.validate_domain_record("schedule", schedule), schedule)
        with self.assertRaisesRegex(protocol.ProtocolError, "schedule.endAt"):
            protocol.validate_domain_record("schedule", {**schedule, "endAt": "1"})
