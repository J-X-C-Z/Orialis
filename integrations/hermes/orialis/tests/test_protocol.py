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
