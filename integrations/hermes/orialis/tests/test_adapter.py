import asyncio
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from gateway.config import Platform
import websockets

from ..adapter import OrialisAdapter
from ..config import OrialisConfig
from ..conversation import chat_id_for_conversation, conversation_id_for_chat_id


class AdapterTests(unittest.TestCase):
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
