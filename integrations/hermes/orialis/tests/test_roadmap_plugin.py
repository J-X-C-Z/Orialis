import asyncio
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from gateway.config import Platform
from gateway.platforms.base import SendResult

from .. import protocol
from ..adapter import OrialisAdapter


class RoadmapProtocolTests(unittest.TestCase):
    def test_structured_lifecycle_frames_round_trip(self):
        frames = [
            protocol.agent_typing(conversation_id="conv", typing=True, session_id="sess", seq=1),
            protocol.agent_start(conversation_id="conv", run_id="run", session_id="sess", seq=2),
            protocol.agent_delta(conversation_id="conv", run_id="run", delta="你好", session_id="sess", seq=3),
            protocol.agent_complete(conversation_id="conv", run_id="run", session_id="sess", seq=4),
            protocol.agent_status(conversation_id="conv", status="completed", session_id="sess", seq=5),
            protocol.tool_event(conversation_id="conv", tool_call_id="tool", tool_name="search", event_type="tool.started", session_id="sess", seq=6),
            protocol.artifact_completed(
                artifact_id="artifact", conversation_id="conv", name="report.txt",
                mime_type="text/plain", session_id="sess", seq=7, uri="https://orialis.test/report.txt",
            ),
        ]
        self.assertEqual(
            [protocol.parse_message(frame)["type"] for frame in frames],
            ["agent.typing", "agent.start", "agent.delta", "agent.complete", "agent.status", "tool.started", "artifact.completed"],
        )

    def test_capability_ack_is_normalized_and_unknown_features_fall_back(self):
        ack = protocol.parse_message(protocol.hello_ack(["typing", "future.v2"]))
        self.assertEqual(protocol.capabilities_from_ack(ack), {"typing"})
        self.assertFalse(protocol.capabilities_from_ack({"version": 1, "type": "hello_ack"}))

    def test_command_and_approval_semantics_are_strict(self):
        slash = protocol.parse_message(protocol.slash_command(
            request_id="slash-1", conversation_id="conv", command="/status", args="--json",
        ))
        self.assertEqual(slash["type"], "slash.command")
        approval = protocol.parse_message(protocol.approval_response(
            request_id="approval-1", conversation_id="conv", choice="once",
        ))
        self.assertEqual(approval["choice"], "once")
        with self.assertRaises(protocol.ProtocolError):
            protocol.parse_message(protocol.approval_response(
                request_id="approval-1", conversation_id="conv", choice="maybe",
            ))


class RoadmapAdapterTests(unittest.TestCase):
    def setUp(self):
        Platform._add_pseudo_member("orialis")
        self.adapter = OrialisAdapter(SimpleNamespace(extra={}))

    def test_delivery_and_command_events_are_deduplicated(self):
        handled = []
        sent = []

        async def send_wire(message):
            sent.append(message)

        async def handle(event):
            handled.append(event)

        self.adapter._send_wire = send_wire
        self.adapter.handle_message = handle
        command = protocol.command_request(
            request_id="cmd-1", conversation_id="conv", command="/status", args="--json",
        )
        delivery = protocol.delivery(
            delivery_id="delivery-1", conversation_id="conv", content="scheduled",
            kind="cron.delivery",
        )

        async def scenario():
            await self.adapter._dispatch_command(command)
            await self.adapter._dispatch_command(command)
            await self.adapter._dispatch_delivery(delivery)
            await self.adapter._dispatch_delivery(delivery)

        asyncio.run(scenario())
        self.assertEqual(len(handled), 2)
        self.assertEqual(sent[0]["type"], "command.reply")
        self.assertEqual([frame["status"] for frame in sent], ["duplicate", "received", "duplicate"])
        self.assertTrue(handled[0].is_command)
        self.assertFalse(handled[1].allow_gateway_control)

    def test_clarify_falls_back_when_peer_does_not_negotiate_it(self):
        sent = []

        async def fake_send(chat_id, content, reply_to=None, metadata=None):
            sent.append((chat_id, content))
            return SendResult(success=True, message_id="fallback")

        self.adapter.send = fake_send
        result = asyncio.run(self.adapter.send_clarify(
            "orialis:conv", "Choose one", ["A", "B"], "clarify-1", "session-1",
        ))
        self.assertTrue(result.success)
        self.assertIn("Choose one", sent[0][1])

    def test_slash_confirm_uses_slash_frame_and_approval_duplicate_is_rejected(self):
        self.adapter._negotiated = True
        self.adapter._server_capabilities = {"slash_commands", "approval"}
        self.adapter._ws = object()
        frames = []

        async def send_request(frame, request_id):
            frames.append(frame)
            return SendResult(success=True, message_id=request_id)

        self.adapter._send_feature_request = send_request
        result = asyncio.run(self.adapter.send_slash_confirm(
            "orialis:conv", "Confirm /reset", "Proceed?", "session-1", "slash-1",
        ))
        self.assertTrue(result.success)
        self.assertEqual(frames[0]["type"], "slash.command")

        sent = []

        async def send_wire(frame):
            sent.append(frame)

        self.adapter._send_wire = send_wire
        self.adapter._pending_interactions["approval-1"] = {
            "kind": "approval", "session_key": "session-1", "conversation_id": "conv",
            "expires_at": 10**20,
        }
        with patch("tools.approval.resolve_gateway_approval", return_value=True) as resolve:
            response = protocol.approval_response(
                request_id="approval-1", conversation_id="conv", choice="once",
            )
            asyncio.run(self.adapter._handle_interaction_response(response))
            asyncio.run(self.adapter._handle_interaction_response(response))
        resolve.assert_called_once()
        self.assertEqual(sent[0]["type"], "message.ack")
        self.assertEqual(sent[1]["type"], "error")
        self.assertEqual(sent[1]["code"], "INTERACTION_NOT_PENDING")

    def test_structured_artifact_event_is_forwarded_once_by_event_id(self):
        handled = []

        async def handle(event):
            handled.append(event)

        self.adapter.handle_message = handle
        event = protocol.artifact_completed(
            artifact_id="artifact-1", conversation_id="conv", name="report.txt",
            mime_type="text/plain", uri="https://orialis.test/report.txt",
            session_id="sess", seq=1, event_id="evt-1",
        )
        asyncio.run(self.adapter._handle_wire(event))
        asyncio.run(self.adapter._handle_wire(event))
        self.assertEqual(len(handled), 1)

    def test_attachment_tempdir_survives_background_claim_and_delivery_namespace_isolated(self):
        handled = []
        sent = []

        async def send_wire(frame):
            sent.append(frame)

        async def handle(event):
            handled.append(event)
            event._gateway_accepted = True

        self.adapter._send_wire = send_wire
        self.adapter.handle_message = handle
        message = {
            "version": 1, "type": "message.send", "message_id": "shared-id",
            "conversation_id": "conv", "content": "file",
            "attachments": [{
                "id": "att", "name": "report.txt", "mime_type": "text/plain",
                "size": 4, "download_url": "https://orialis.test/report.txt",
            }],
        }
        delivery = protocol.delivery(
            delivery_id="shared-id", conversation_id="conv", content="scheduled",
            kind="cron.delivery",
        )

        def fake_download(item, server_url, destination, token=None, device_id=None):
            Path(destination).write_bytes(b"test")
            return "text/plain"

        async def scenario():
            with patch("integrations.hermes.orialis.adapter._download_attachment", fake_download):
                await self.adapter._dispatch_message(message)
            await self.adapter._dispatch_delivery(delivery)

        asyncio.run(scenario())
        self.assertEqual(len(handled), 2)
        path = Path(handled[0].media_urls[0])
        self.assertTrue(path.exists())
        asyncio.run(self.adapter.on_processing_complete(handled[0], SimpleNamespace(value="success")))
        self.assertFalse(path.exists())
