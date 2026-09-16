from __future__ import annotations

import asyncio
import json
import os
import unittest

from .support import LiveServerMixin, json_request, request, session_headers, unique_id, wait_for_message

try:
    import websockets
except ImportError:  # pragma: no cover - intentionally visible as a test skip
    websockets = None


def ws_kwargs() -> dict:
    token = os.environ.get("ORIALIS_ROADMAP_AGENT_TOKEN") or os.environ.get("ORIALIS_DEVICE_TOKEN")
    return {"additional_headers": {"Authorization": f"Bearer {token}"}} if token else {}


async def receive_json(socket, timeout: float = 5.0) -> dict:
    return json.loads(await asyncio.wait_for(socket.recv(), timeout=timeout))


class LiveAgentGatewayTests(LiveServerMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        if websockets is None:
            raise unittest.SkipTest("Agent Gateway WebSocket tests require the optional websockets package")

    def test_handshake_unknown_frame_and_ping_recovery(self) -> None:
        asyncio.run(self._handshake_unknown_frame_and_ping_recovery())

    async def _handshake_unknown_frame_and_ping_recovery(self) -> None:
        self.shared_session()
        ws_url = self._ws_url("/api/v1/agent/ws")
        async with websockets.connect(ws_url, **ws_kwargs()) as socket:
            await socket.send(json.dumps({
                "version": 1,
                "type": "hello",
                "device_id": "ROADMAP_TEST_Gateway",
                "client": "roadmap-black-box",
                "plugin_version": "test",
                "platform": "test",
            }))
            hello_ack = await receive_json(socket)
            self.assertEqual(hello_ack, {"version": 1, "type": "hello_ack"})

            await socket.send(json.dumps({"version": 1, "type": "future.roadmap.event"}))
            error = await receive_json(socket)
            self.assertEqual(error["type"], "error")
            self.assertEqual(error["code"], "UNKNOWN_TYPE")

            await socket.send(json.dumps({"version": 1, "type": "ping"}))
            self.assertEqual(await receive_json(socket), {"version": 1, "type": "pong"})

    def test_capability_negotiation_and_ordered_agent_event_acknowledgements(self) -> None:
        asyncio.run(self._capability_negotiation_and_ordered_agent_event_acknowledgements())

    async def _capability_negotiation_and_ordered_agent_event_acknowledgements(self) -> None:
        self.shared_session()
        async with websockets.connect(self._ws_url("/api/v1/agent/ws"), **ws_kwargs()) as socket:
            await socket.send(json.dumps({
                "version": 1,
                "type": "hello",
                "device_id": "ROADMAP_TEST_Events",
                "client": "roadmap-black-box",
                "plugin_version": "test",
                "platform": "macos",
            }))
            self.assertEqual((await receive_json(socket))["type"], "hello_ack")

            await socket.send(json.dumps({
                "version": 1,
                "type": "capabilities.hello",
                "capabilities": [
                    "agent.typing", "agent.delta", "agent.status", "tool.progress",
                    "clarify.resolve", "approval.resolve", "session.start", "artifact.completed",
                ],
                "resume_from": 0,
            }))
            capabilities = await receive_json(socket)
            self.assertEqual(capabilities["type"], "capabilities.ack")
            self.assertIn("agent.typing", capabilities["capabilities"])
            self.assertEqual(capabilities["resume_from"], 0)
            self.assertGreaterEqual(capabilities["next_seq"], 1)

            session = "roadmap-session"
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "agent.typing", "event_id": "evt-typing-1",
                "seq": 1, "session_id": session, "typing": True,
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "agent.start", "event_id": "evt-start-1",
                "seq": 2, "session_id": session, "run_id": "run-1",
            }, "received")
            delta = {
                "version": 1, "type": "agent.delta", "event_id": "evt-delta-1",
                "seq": 3, "session_id": session, "run_id": "run-1", "delta": "hello",
            }
            await self._send_and_expect_ack(socket, delta, "received")
            duplicate = {**delta, "event_id": "evt-delta-duplicate"}
            await self._send_and_expect_ack(socket, duplicate, "duplicate")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "agent.complete", "event_id": "evt-complete-gap",
                "seq": 5, "session_id": session, "run_id": "run-1", "content": "hello",
            }, "gap", expected_seq=4)

            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "agent.status", "event_id": "evt-status-1",
                "seq": 4, "session_id": session, "status": "running", "message": "working",
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "tool.started", "event_id": "evt-tool-start",
                "seq": 5, "session_id": session, "tool_call_id": "tool-1", "tool_name": "search",
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "tool.progress", "event_id": "evt-tool-progress",
                "seq": 6, "session_id": session, "tool_call_id": "tool-1", "progress": {"step": 1},
            }, "received")

            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "clarify.request", "event_id": "evt-clarify-request",
                "seq": 7, "session_id": session, "request_id": "clarify-1",
                "question": "Which project?", "options": [],
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "clarify.resolve", "event_id": "evt-clarify-resolve",
                "seq": 8, "session_id": session, "request_id": "clarify-1", "answer": "Orialis",
            }, "received")

            for index, decision in enumerate(("once", "session", "always", "deny"), start=1):
                request_id = f"approval-{index}"
                request_seq = 9 + (index - 1) * 2
                await self._send_and_expect_ack(socket, {
                    "version": 1, "type": "approval.request", "event_id": f"evt-approval-request-{index}",
                    "seq": request_seq, "session_id": session, "request_id": request_id,
                    "action": "run tool", "details": {},
                }, "received")
                await self._send_and_expect_ack(socket, {
                    "version": 1, "type": "approval.resolve", "event_id": f"evt-approval-resolve-{index}",
                    "seq": request_seq + 1, "session_id": session, "request_id": request_id,
                    "decision": decision,
                }, "received")

            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "approval.request", "event_id": "evt-approval-duplicate-request",
                "seq": 17, "session_id": session, "request_id": "approval-duplicate", "action": "run tool",
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "approval.resolve", "event_id": "evt-approval-duplicate-resolve",
                "seq": 18, "session_id": session, "request_id": "approval-duplicate", "decision": "deny",
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "approval.resolve", "event_id": "evt-approval-duplicate-again",
                "seq": 19, "session_id": session, "request_id": "approval-duplicate", "decision": "deny",
            }, "unknown")
            unknown_error = await receive_json(socket)
            self.assertEqual(unknown_error["type"], "error")
            self.assertEqual(unknown_error["code"], "UNKNOWN_APPROVAL")

            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "approval.request", "event_id": "evt-approval-timeout",
                "seq": 20, "session_id": session, "request_id": "approval-timeout", "action": "run tool",
                "timeout_ms": 1,
            }, "received")
            timeout_event = await receive_json(socket, timeout=2.5)
            self.assertEqual(timeout_event["type"], "approval.resolve")
            self.assertEqual(timeout_event["request_id"], "approval-timeout")
            self.assertEqual(timeout_event["decision"], "timeout")

            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "session.start", "event_id": "evt-session-start",
                "seq": 21, "session_id": session, "conversation_id": "conversation-1",
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "session.update", "event_id": "evt-session-update",
                "seq": 22, "session_id": session, "update": {"status": "working"},
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "session.complete", "event_id": "evt-session-complete",
                "seq": 23, "session_id": session, "result": {"ok": True},
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "artifact.started", "event_id": "evt-artifact-start",
                "seq": 24, "session_id": session,
                "artifact": {"id": "artifact-1", "kind": "document", "name": "report.txt"},
            }, "received")
            await self._send_and_expect_ack(socket, {
                "version": 1, "type": "artifact.completed", "event_id": "evt-artifact-complete",
                "seq": 25, "session_id": session,
                "artifact": {"id": "artifact-1", "kind": "document", "name": "report.txt", "size": 12},
            }, "received")

    async def _send_and_expect_ack(
        self, socket, frame: dict, status: str, *, expected_seq: int | None = None
    ) -> None:
        await socket.send(json.dumps(frame))
        ack = await receive_json(socket)
        self.assertEqual(ack["type"], "agent.ack")
        self.assertEqual(ack["event_id"], frame["event_id"])
        self.assertEqual(ack["seq"], frame["seq"])
        self.assertEqual(ack["status"], status)
        if expected_seq is None:
            self.assertNotIn("expected_seq", ack)
        else:
            self.assertEqual(ack.get("expected_seq"), expected_seq)

    def test_mobile_message_is_delivered_to_agent_and_reply_is_persisted(self) -> None:
        asyncio.run(self._mobile_message_is_delivered_to_agent_and_reply_is_persisted())

    async def _mobile_message_is_delivered_to_agent_and_reply_is_persisted(self) -> None:
        token, _ = self.shared_session()
        conversation = unique_id("roadmap-agent-conversation")
        message_id = unique_id("roadmap-agent-message")
        created = await asyncio.to_thread(
            json_request,
            "POST",
            "/api/v1/conversations",
            {"id": conversation, "title": "Roadmap delivery test"},
            headers=session_headers(token),
        )
        self.assertIn(created.status, (200, 201), created.body)
        async with websockets.connect(self._ws_url("/api/v1/agent/ws"), **ws_kwargs()) as socket:
            await socket.send(json.dumps({
                "version": 1,
                "type": "hello",
                # The first connected device is the server's active target;
                # reconnect it here so the test exercises delivery rather
                # than intentionally queued delivery to an offline device.
                "device_id": "ROADMAP_TEST_Events",
                "client": "roadmap-black-box",
                "plugin_version": "test",
                "platform": "test",
            }))
            handshake = await receive_json(socket)
            if handshake.get("type") == "error":
                if handshake.get("code") == "AGENT_OWNER_REQUIRED":
                    self.skipTest("server has multiple users and no ORIALIS_AGENT_USER_ID")
                self.fail(f"Agent Gateway handshake failed: {handshake}")
            self.assertEqual(handshake["type"], "hello_ack")

            post_task = asyncio.create_task(asyncio.to_thread(
                json_request,
                "POST",
                f"/api/v1/conversations/{conversation}/messages",
                {"id": message_id, "content": "cross-layer delivery"},
                headers=session_headers(token),
            ))
            sent = await receive_json(socket)
            posted = await post_task
            self.assertEqual(posted.status, 201, posted.body)
            self.assertEqual(sent["type"], "message.send")
            self.assertEqual(sent["message_id"], message_id)
            self.assertEqual(sent["content"], "cross-layer delivery")
            self.assertEqual(sent["conversation_id"], conversation)

            await socket.send(json.dumps({
                "version": 1,
                "type": "message.ack",
                "message_id": message_id,
                "status": "received",
            }))
            reply_id = unique_id("roadmap-agent-reply")
            await socket.send(json.dumps({
                "version": 1,
                "type": "message.reply",
                "message_id": reply_id,
                "reply_to": message_id,
                "conversation_id": conversation,
                "content": "cross-layer reply",
            }))
            server_ack = await receive_json(socket)
            self.assertEqual(server_ack["type"], "message.ack")
            self.assertEqual(server_ack["message_id"], reply_id)

        messages = wait_for_message(
            f"/api/v1/conversations/{conversation}/messages",
            token,
            lambda values: any(
                item.get("role") == "assistant" and item.get("content") == "cross-layer reply"
                for item in values
            ),
        )
        self.assertTrue(any(item["role"] == "assistant" for item in messages))

    def _ws_url(self, path: str) -> str:
        from urllib.parse import urlsplit, urlunsplit

        parsed = urlsplit(self._base_url())
        scheme = "wss" if parsed.scheme == "https" else "ws"
        return urlunsplit((scheme, parsed.netloc, path, "", ""))

    def _base_url(self) -> str:
        from .support import base_url

        return base_url()
