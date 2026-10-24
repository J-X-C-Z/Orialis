import asyncio
import os
import tempfile
import json
import base64
import unittest
from types import SimpleNamespace
from unittest.mock import patch
from pathlib import Path

from gateway.config import Platform
import websockets

from .. import adapter as adapter_module
from ..adapter import OrialisAdapter
from ..config import OrialisConfig
from ..conversation import chat_id_for_conversation, conversation_id_for_chat_id


class AdapterTests(unittest.TestCase):
    def test_full_size_workspace_upload_crosses_real_websocket(self):
        Platform._add_pseudo_member("orialis")
        with tempfile.TemporaryDirectory() as directory:
            raw = b"x" * (1024 * 1024)

            async def scenario():
                complete = asyncio.get_running_loop().create_future()

                async def fake_server(socket):
                    await socket.recv()
                    await socket.send(json.dumps({"version":1,"type":"hello_ack"}))
                    await socket.send(json.dumps({"version":1,"type":"workspace.request","request_id":"large-file",
                        "conversation_id":"chat-1","payload":{"op":"upload","workspaceId":"w0","path":"full.bin",
                        "base64":base64.b64encode(raw).decode()}}))
                    while True:
                        message = json.loads(await socket.recv())
                        if message["type"] == "workspace.response":
                            complete.set_result(message)
                            return

                async with websockets.serve(fake_server, "127.0.0.1", 0) as server:
                    port = server.sockets[0].getsockname()[1]
                    adapter = OrialisAdapter(SimpleNamespace(extra={"server_url":f"ws://127.0.0.1:{port}",
                        "device_id":"JXCZ_TEST_Hermes","workspaces":[{"path":directory}]}))
                    try:
                        self.assertTrue(await adapter.connect())
                        response = await asyncio.wait_for(complete, timeout=10)
                        self.assertTrue(response["payload"]["ok"], response)
                        self.assertEqual(response["payload"]["data"]["size"], len(raw))
                    finally:
                        await adapter.disconnect()

            asyncio.run(scenario())
            self.assertEqual(Path(directory, "full.bin").read_bytes(), raw)

    def test_actual_server_flat_resolves_keep_conversation_scope_and_ack_real_resolver(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter._ws = object()
        sent = []

        async def send_wire(frame):
            sent.append(frame)

        adapter._send_wire = send_wire
        fixtures = Path(__file__).parent / "fixtures"
        for kind in ("approval", "clarify"):
            adapter._pending_interactions[f"{kind}-1"] = {"kind": kind, "session_key": "hermes-session",
                "conversation_id": "chat-1", "expires_at": 10**20}
        with patch("tools.approval.resolve_gateway_approval", return_value=True) as approval, \
             patch("tools.clarify_gateway.resolve_gateway_clarify", return_value=True) as clarify:
            for kind in ("approval", "clarify"):
                frame = (fixtures / f"server-{kind}-resolve-v1.json").read_text()
                asyncio.run(adapter._handle_wire(frame))
        approval.assert_called_once_with("hermes-session", "once", reason=None, request_id="approval-1")
        clarify.assert_called_once_with("clarify-1", "Chosen answer")
        self.assertEqual([(f["type"], f.get("status")) for f in sent], [("message.ack", "resolved")] * 2)

        adapter._pending_interactions["approval-2"] = {"kind": "approval", "session_key": "hermes-session",
            "conversation_id": "chat-1", "expires_at": 10**20}
        wrong = json.loads((fixtures / "server-approval-resolve-v1.json").read_text())
        wrong.update(request_id="approval-2", session_id="other-chat")
        with patch("tools.approval.resolve_gateway_approval") as approval:
            asyncio.run(adapter._handle_wire(json.dumps(wrong)))
        approval.assert_not_called()
        self.assertEqual(sent[-1]["code"], "INTERACTION_SCOPE_MISMATCH")
        self.assertIn("approval-2", adapter._pending_interactions)
        wrong["session_id"] = "chat-1"
        with patch("tools.approval.resolve_gateway_approval", side_effect=[False, True]) as approval:
            asyncio.run(adapter._handle_wire(json.dumps(wrong)))
            self.assertEqual(sent[-1]["type"], "error")
            self.assertIn("approval-2", adapter._pending_interactions)
            asyncio.run(adapter._handle_wire(json.dumps(wrong)))
        self.assertEqual(approval.call_count, 2)
        self.assertEqual(sent[-1]["status"], "resolved")

    def test_workspace_requests_execute_without_prompting_agent(self):
        Platform._add_pseudo_member("orialis")
        with tempfile.TemporaryDirectory() as directory:
            adapter = OrialisAdapter(SimpleNamespace(extra={"workspaces": [{"path": directory}]}))
            sent = []

            async def send_wire(message):
                sent.append(message)

            async def must_not_prompt(event):
                self.fail("workspace requests must never prompt a model")

            adapter._send_wire = send_wire
            adapter.handle_message = must_not_prompt
            asyncio.run(adapter._handle_wire({"version": 1, "type": "workspace.request", "request_id": "req-1",
                "conversation_id": "chat-1", "payload": {"op": "capabilities"}}))
            self.assertEqual(sent[0]["type"], "workspace.response")
            self.assertEqual(sent[0]["request_id"], "req-1")
            self.assertEqual(sent[0]["conversation_id"], "chat-1")
            self.assertTrue(sent[0]["payload"]["ok"])
            self.assertFalse(sent[0]["payload"]["data"]["workspaces"][0]["terminalEnabled"])

    def setUp(self):
        home = tempfile.TemporaryDirectory()
        cache_type = adapter_module.AttachmentCache

        def isolated_cache(*args):
            with patch.dict(os.environ, {"HERMES_HOME": home.name}):
                return cache_type(*args)

        cache_patch = patch.object(adapter_module, "AttachmentCache", isolated_cache)
        cache_patch.start()
        self.addCleanup(home.cleanup)
        self.addCleanup(cache_patch.stop)

    def test_conversations_have_stable_isolated_chat_ids(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))

        first = chat_id_for_conversation("conv:A/1")
        second = chat_id_for_conversation("conv:B/1")
        first_source = adapter.build_source(first, chat_type="dm", user_id="test-device")
        second_source = adapter.build_source(second, chat_type="dm", user_id="test-device")

        first_key = adapter._source_session_key(first_source)
        second_key = adapter._source_session_key(second_source)
        repeat_key = adapter._source_session_key(
            adapter.build_source(chat_id_for_conversation("conv:A/1"), chat_type="dm", user_id="test-device")
        )

        self.assertNotEqual(first_key, second_key)
        self.assertEqual(first_key, repeat_key)
        self.assertEqual(conversation_id_for_chat_id(first), "conv:A/1")
        self.assertEqual(conversation_id_for_chat_id(second), "conv:B/1")

    def test_config_reads_platform_extra(self):
        config = OrialisConfig.from_platform_config(SimpleNamespace(extra={
            "server_url": "ws://127.0.0.1:18443/api/v1/agent/ws",
            "device_id": "JXCZ_MBA_Hermes",
        }))
        self.assertTrue(config.server_url.endswith("/api/v1/agent/ws"))
        self.assertEqual(config.device_id, "JXCZ_MBA_Hermes")

    def test_nonconversational_heartbeat_becomes_transient_working_status(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter._ws = object()
        adapter._running = True
        chat_id = chat_id_for_conversation("chat-1")
        adapter._processing_status[chat_id] = {"status": "running", "message": "正在处理请求", "run_id": "user-42"}
        calls = []

        async def send_status(*args, **kwargs):
            calls.append((args, kwargs))
            return True

        adapter.send_agent_state = send_status
        result = asyncio.run(adapter.send(
            chat_id, "⏳ Working — 3 min — iteration 1/60, research_market",
            metadata={"non_conversational": True},
        ))

        self.assertTrue(result.success)
        self.assertIsNone(result.message_id)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0][:2], (chat_id, "working"))
        self.assertEqual(calls[0][1], {
            "run_id": "user-42", "message": "⏳ Working — 3 min — iteration 1/60, research_market",
        })

    def test_nonconversational_background_review_notice_is_suppressed(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter._ws = object()
        adapter._running = True
        sent = []

        async def send_wire(frame):
            sent.append(frame)

        adapter._send_wire = send_wire
        result = asyncio.run(adapter.send(
            chat_id_for_conversation("chat-1"),
            "💾 Self-improvement review: Memory updated",
            metadata={"non_conversational": True},
        ))

        self.assertTrue(result.success)
        self.assertIsNone(result.message_id)
        self.assertEqual(sent, [])

    def test_unrecognized_nonconversational_notice_still_persists_as_reply(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter._ws = object()
        adapter._running = True
        adapter._reply_anchors[chat_id_for_conversation("chat-1")] = "user-42"
        sent = []

        async def send_wire(frame):
            sent.append(frame)
            if frame["type"] == "message.reply":
                await adapter._handle_wire({
                    "version": 1, "type": "message.ack", "message_id": frame["message_id"], "status": "received",
                })

        adapter._send_wire = send_wire
        result = asyncio.run(adapter.send(
            chat_id_for_conversation("chat-1"), "普通的后台通知",
            metadata={"non_conversational": True},
        ))

        self.assertTrue(result.success)
        self.assertEqual(sent[0]["type"], "message.reply")
        self.assertEqual(sent[0]["content"], "普通的后台通知")

    def test_review_looking_assistant_reply_without_internal_marker_is_preserved(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter._ws = object()
        adapter._running = True
        chat_id = chat_id_for_conversation("chat-1")
        adapter._reply_anchors[chat_id] = "user-42"
        sent = []

        async def send_wire(frame):
            sent.append(frame)
            if frame["type"] == "message.reply":
                await adapter._handle_wire({
                    "version": 1, "type": "message.ack", "message_id": frame["message_id"], "status": "received",
                })

        adapter._send_wire = send_wire
        result = asyncio.run(adapter.send(chat_id, "💾 Self-improvement review: Memory updated"))

        self.assertTrue(result.success)
        self.assertEqual(sent[0]["type"], "message.reply")

    def test_recognized_review_notice_with_attachment_uses_normal_delivery(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter._ws = object()
        adapter._running = True
        chat_id = chat_id_for_conversation("chat-1")
        adapter._reply_anchors[chat_id] = "user-42"
        sent = []

        async def send_wire(frame):
            sent.append(frame)
            if frame["type"] == "message.reply":
                await adapter._handle_wire({
                    "version": 1, "type": "message.ack", "message_id": frame["message_id"], "status": "received",
                })

        adapter._send_wire = send_wire
        attachment = {"id": "file-1", "name": "review.txt", "mime_type": "text/plain"}
        result = asyncio.run(adapter.send(
            chat_id, "💾 Self-improvement review: Memory updated",
            metadata={"non_conversational": True, "attachments": [attachment]},
        ))

        self.assertTrue(result.success)
        self.assertEqual(sent[0]["type"], "message.reply")
        self.assertEqual(sent[0]["attachments"], [attachment])

    def test_hello_and_message_reply_builders(self):
        from ..protocol import ack, hello, parse_message, reply

        self.assertEqual(parse_message(hello("JXCZ_MBA_Hermes"))["type"], "hello")
        self.assertEqual(parse_message(reply(
            message_id="msg_2", reply_to="msg_1", conversation_id="conv_1", content="2"
        ))["reply_to"], "msg_1")
        self.assertEqual(parse_message(ack("msg_2"))["type"], "message.ack")

    def test_disconnect_without_connection_is_safe(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        asyncio.run(adapter.disconnect())

    def test_connect_dispatches_message_and_sends_reply(self):
        Platform._add_pseudo_member("orialis")

        async def scenario():
            received = {}

            async def fake_server(socket):
                received["hello"] = json.loads(await socket.recv())
                await socket.send(json.dumps({"version": 1, "type": "hello_ack"}))
                await socket.send(json.dumps({
                    "version": 1,
                    "type": "message.send",
                    "message_id": "msg_1",
                    "conversation_id": "conv_1",
                    "content": "请回复 ORIALIS_OK",
                }, ensure_ascii=False))
                received["ack"] = json.loads(await socket.recv())
                received["reply"] = json.loads(await socket.recv())
                await socket.send(json.dumps({
                    "version": 1,
                    "type": "message.ack",
                    "message_id": received["reply"]["message_id"],
                    "status": "received",
                }))

            server = await websockets.serve(fake_server, "127.0.0.1", 0)
            port = server.sockets[0].getsockname()[1]
            adapter = OrialisAdapter(SimpleNamespace(extra={
                "server_url": f"ws://127.0.0.1:{port}",
                "device_id": "JXCZ_TEST_Hermes",
            }))

            async def handle_message(event):
                result = await adapter.send(event.source.chat_id, "ORIALIS_OK", reply_to=event.message_id)
                self.assertTrue(result.success)

            adapter.handle_message = handle_message
            try:
                self.assertTrue(await adapter.connect())
                for _ in range(20):
                    if "reply" in received:
                        break
                    await asyncio.sleep(0.01)
            finally:
                await adapter.disconnect()
                server.close()
                await server.wait_closed()

            self.assertEqual(received["hello"]["type"], "hello")
            self.assertEqual(received["hello"]["device_id"], "JXCZ_TEST_Hermes")
            self.assertEqual(received["ack"]["type"], "message.ack")
            self.assertEqual(received["ack"]["message_id"], "msg_1")
            self.assertEqual(received["reply"]["type"], "message.reply")
            self.assertEqual(received["reply"]["reply_to"], "msg_1")
            self.assertEqual(received["reply"]["content"], "ORIALIS_OK")

        asyncio.run(scenario())

    def test_duplicate_message_is_acked_without_redispatch(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        sent = []
        handled = []

        async def fake_send(message):
            sent.append(message)

        async def fake_handle(event):
            handled.append(event)

        adapter._send_wire = fake_send
        adapter.handle_message = fake_handle
        message = {
            "version": 1,
            "type": "message.send",
            "message_id": "duplicate_001",
            "conversation_id": "conv_001",
            "content": "hello",
        }
        asyncio.run(adapter._dispatch_message(message))
        asyncio.run(adapter._dispatch_message(message))

        self.assertEqual(len(handled), 1)
        self.assertEqual([item["type"] for item in sent], ["message.ack", "message.ack"])

    def test_inbound_attachment_survives_dispatch(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={
            "server_url": "https://orialis.test/api/v1/agent/ws",
            "device_id": "JXCZ_TEST_Hermes",
        }))
        sent, observed = [], []

        async def send_wire(message):
            sent.append(message)

        adapter._send_wire = send_wire

        async def handle(event):
            observed.append((event.media_urls[0], event.media_types[0]))
            self.assertTrue(Path(event.media_urls[0]).exists())

        from pathlib import Path
        adapter.handle_message = handle
        message = {"version": 1, "type": "message.send", "message_id": "m-media",
                   "conversation_id": "conv", "content": "read",
                   "attachments": [{"id": "a", "name": "../notes.txt", "mime_type": "text/plain",
                                    "size": 4, "download_url": "https://orialis.test/a"}]}

        def fake_download(item, server_url, destination, token=None, device_id=None):
            destination.write_bytes(b"test")
            return "text/plain"

        with patch.object(adapter_module, "_download_attachment", fake_download):
            asyncio.run(adapter._dispatch_message(message))
        self.assertEqual(observed[0][1], "text/plain")
        self.assertTrue(Path(observed[0][0]).exists())

    def test_reconnect_uses_bounded_exponential_backoff(self):
        Platform._add_pseudo_member("orialis")
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        delays = []
        attempts = []

        async def fake_sleep(delay):
            delays.append(delay)

        async def fake_connect(*, is_reconnect=False):
            attempts.append(is_reconnect)
            return len(attempts) == 3

        async def scenario():
            with patch("integrations.hermes.orialis.adapter.asyncio.sleep", new=fake_sleep):
                adapter.connect = fake_connect
                await adapter._reconnect_loop()

        asyncio.run(scenario())
        self.assertEqual(delays, [1.0, 2.0, 4.0])
        self.assertEqual(attempts, [True, True, True])
