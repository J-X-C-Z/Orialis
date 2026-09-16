from __future__ import annotations

import json
import unittest
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = ROOT / "protocol" / "agent-gateway" / "examples"
EVENT_FIXTURES = {
    "clarify_requested.json": ("clarify.request", ("request_id", "question", "choices")),
    "approval_requested.json": ("approval.request", ("request_id", "action", "timeout_ms")),
    "session_start.json": ("session.start", ("event_id", "seq", "session_id")),
    "artifact_ready.json": ("artifact.completed", ("event_id", "seq", "session_id")),
}
DESIGN_FIXTURES = {
    "command_request.json": ("command.request", ("request_id", "conversation_id", "command")),
    "cron_delivery.json": ("cron.delivery", ("delivery_id", "conversation_id", "content")),
}


def assert_text(value: Any, field: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise AssertionError(f"{field} must be non-blank text")


def assert_attachment(value: Any) -> None:
    if not isinstance(value, dict):
        raise AssertionError("attachment must be an object")
    for field in ("id", "name", "mime_type", "size", "download_url"):
        if field not in value:
            raise AssertionError(f"attachment fixture is missing {field}")
    for field in ("id", "name", "mime_type", "download_url"):
        assert_text(value[field], f"attachment.{field}")
    if not isinstance(value["size"], int) or isinstance(value["size"], bool) or value["size"] < 1:
        raise AssertionError("attachment.size must be a positive integer")
    mime = value["mime_type"].lower()
    if mime.startswith(("audio/", "video/")):
        raise AssertionError("voice/video metadata must not enter the non-voice contract")


class ExistingGatewayFixtureContractTests(unittest.TestCase):
    def load(self, name: str) -> dict[str, Any]:
        path = FIXTURE_DIR / name
        if not path.exists():
            self.skipTest(f"static protocol fixture is unavailable: {path}")
        with path.open(encoding="utf-8") as source:
            value = json.load(source)
        self.assertIsInstance(value, dict, name)
        self.assertEqual(value.get("version"), 1, name)
        self.assertIsInstance(value.get("type"), str, name)
        return value

    def test_existing_hello_fixture_is_a_real_handshake_frame(self) -> None:
        value = self.load("hello.json")
        self.assertEqual(value["type"], "hello")
        for field in ("device_id", "client", "plugin_version", "platform"):
            assert_text(value.get(field), field)
        self.assertEqual(len(value["device_id"].split("_")), 3)

    def test_existing_message_fixtures_preserve_attachment_metadata(self) -> None:
        for name in ("message_send.json", "message_reply.json"):
            value = self.load(name)
            self.assertIn(value["type"], {"message.send", "message.reply"})
            for field in ("message_id", "conversation_id"):
                assert_text(value.get(field), field)
            if value["type"] == "message.reply":
                assert_text(value.get("reply_to"), "reply_to")
            attachments = value.get("attachments", [])
            self.assertIsInstance(attachments, list, name)
            for attachment in attachments:
                assert_attachment(attachment)
            self.assertTrue(value.get("content", "").strip() or attachments)

    def test_existing_ack_fixture_is_not_completion_semantics(self) -> None:
        value = self.load("message_ack.json")
        self.assertEqual(value["type"], "message.ack")
        assert_text(value.get("message_id"), "message_id")
        self.assertEqual(value.get("status"), "received")

    def test_non_voice_attachment_policy_is_explicit(self) -> None:
        for name in ("message_send.json", "message_reply.json", "artifact_ready.json"):
            value = self.load(name)
            candidates = value.get("attachments", [])
            if value.get("type") == "artifact.completed":
                candidates = [value["artifact"]]
            for attachment in candidates:
                mime = attachment.get("mime_type", "").lower()
                self.assertFalse(mime.startswith(("audio/", "video/")), name)

    def test_reserved_event_fixtures_match_event_v1_shape(self) -> None:
        previous_sequence = 0
        loaded_events = [(name, expected, self.load(name)) for name, expected in EVENT_FIXTURES.items()]
        for name, (event_type, required_payload), value in sorted(
            loaded_events, key=lambda item: item[2]["seq"]
        ):
            self.assertEqual(value["type"], event_type, name)
            for field in ("event_id", "seq", "session_id"):
                self.assertIn(field, value, name)
            assert_text(value["event_id"], "event_id")
            assert_text(value["session_id"], "session_id")
            self.assertIsInstance(value["seq"], int, name)
            self.assertGreater(value["seq"], previous_sequence, name)
            previous_sequence = value["seq"]
            for field in required_payload:
                self.assertIn(field, value, name)
            if event_type == "approval.request":
                self.assertGreater(value["timeout_ms"], 0)
            if event_type == "clarify.request":
                self.assertIsInstance(value["choices"], list, name)
            if event_type == "artifact.completed":
                assert_attachment({
                    "id": value["artifact"]["id"],
                    "name": value["artifact"]["name"],
                    "mime_type": value["artifact"]["mime_type"],
                    "size": value["artifact"]["size"],
                    "download_url": value["artifact"]["uri"],
                })

        for name, (message_type, required_fields) in DESIGN_FIXTURES.items():
            value = self.load(name)
            self.assertEqual(value["type"], message_type, name)
            for field in required_fields:
                self.assertIn(field, value, name)
            if message_type == "cron.delivery":
                self.assertIsInstance(value["metadata"], dict, name)

    def test_reserved_event_type_is_not_silently_treated_as_baseline_message(self) -> None:
        for name in (*EVENT_FIXTURES, *DESIGN_FIXTURES):
            value = self.load(name)
            self.assertNotIn(value["type"], {"message.send", "message.reply"})
