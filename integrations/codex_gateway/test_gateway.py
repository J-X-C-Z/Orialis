import asyncio
import json
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from pathlib import Path

from gateway import Codex, Gateway, NewsPublisher, Store, frame


class FakeCodex:
    def __init__(self):
        self.calls = []
        self.active = set()
        self.running = self.peak = 0

    async def run(self, content, thread, on_thread):
        if thread is not None and thread in self.active:
            raise AssertionError("Same conversation executed concurrently")
        self.active.add(thread)
        self.calls.append((content, thread))
        self.running += 1
        self.peak = max(self.peak, self.running)
        on_thread(thread or "thread-" + content)
        await asyncio.sleep(0.02)
        self.active.discard(thread)
        self.running -= 1
        return "reply-" + content


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "state.sqlite"
        self.store = Store(self.path)
        self.codex = FakeCodex()
        self.gateway = Gateway(self.store, self.codex)
        self.sent = []

    def tearDown(self):
        self.store.db.close()
        self.temp.cleanup()

    async def send(self, value):
        self.sent.append(value)

    def message(self, id="m1", conversation="c1", content="one", **extra):
        return frame("message.send", message_id=id, conversation_id=conversation, content=content, **extra)

    async def drain(self):
        await asyncio.gather(*self.gateway.tasks)

    async def test_duplicate_and_reconnect_replay_exact_reply(self):
        async def disconnected(value):
            raise OSError("disconnected")
        with self.assertRaises(OSError):
            await self.gateway.handle(self.message(), disconnected)
        await self.drain()
        await self.gateway.handle(self.message(), self.send)
        reply = self.sent[-1]
        await self.gateway.handle(self.message(), self.send)
        self.assertEqual(self.sent[-1], reply)
        self.assertEqual(len(self.codex.calls), 1)

    async def test_conversation_thread_isolation_and_serial_order(self):
        await self.gateway.handle(self.message(), self.send)
        await self.gateway.handle(self.message("m2", content="two"), self.send)
        await self.drain()
        await self.gateway.handle(self.message("m3", "c2", "three"), self.send)
        await self.drain()
        self.assertEqual(self.codex.calls, [("one", None), ("two", "thread-one"), ("three", None)])
        self.assertEqual(self.store.thread("c2"), "thread-three")

    async def test_restart_does_not_repeat_uncertain_execution(self):
        self.store.claim(self.message())
        self.store.db.close()
        self.store = Store(self.path)
        self.gateway = Gateway(self.store, self.codex)
        await self.gateway.handle(self.message(), self.send)
        self.assertEqual(self.sent[-1]["code"], "EXECUTION_UNCERTAIN")
        self.assertEqual(self.codex.calls, [])

    async def test_different_conversations_can_execute_concurrently(self):
        await self.gateway.handle(self.message(), self.send)
        await self.gateway.handle(self.message("m2", "c2", "two"), self.send)
        await self.drain()
        self.assertEqual(self.codex.peak, 2)
        self.assertEqual(self.store.thread("c1"), "thread-one")
        self.assertEqual(self.store.thread("c2"), "thread-two")

    async def test_json_events_capture_thread_and_final_response(self):
        executable = Path(self.temp.name) / "fake-codex"
        executable.write_text('#!/usr/bin/env python3\nimport json,sys\n'
            'sys.stdin.read()\n'
            'print(json.dumps({"type":"thread.started","thread_id":"new-id"}))\n'
            'print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"done"}}))\n')
        executable.chmod(0o700)
        ids = []
        result = await Codex(self.temp.name, self.temp.name, str(executable)).run("hello", None, ids.append)
        self.assertEqual(ids, ["new-id"])
        self.assertEqual(result, "done")

    async def test_attachment_command_and_conflicting_id_rejected(self):
        await self.gateway.handle(self.message(attachments=[{"id": "attachment"}]), self.send)
        await self.drain()
        self.assertEqual(self.sent[-1]["code"], "UNSUPPORTED_ATTACHMENT")
        await self.gateway.handle(frame("command.request", request_id="r1", command="model"), self.send)
        self.assertEqual(self.sent[-1]["code"], "UNSUPPORTED_OPERATION")
        await self.gateway.handle(self.message(content="different"), self.send)
        self.assertEqual(self.sent[-1]["code"], "MESSAGE_ID_CONFLICT")
        self.assertEqual(self.codex.calls, [])

    async def test_timeout_process_is_killed(self):
        executable = Path(self.temp.name) / "fake-codex"
        executable.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n")
        executable.chmod(0o700)
        client = Codex(self.temp.name, self.temp.name, str(executable), timeout=0.03)
        with self.assertRaises(asyncio.TimeoutError):
            await client.run("hello", None, lambda thread: None)

    def test_command_uses_explicit_thread_and_read_only(self):
        command = Codex("/tmp/home", "/tmp").command("uuid-thread")
        self.assertIn('sandbox_mode="read-only"', command)
        self.assertIn('approval_policy="never"', command)
        self.assertEqual(command[-3:], ["resume", "uuid-thread", "-"])
        self.assertNotIn("--last", command)

    def test_empty_mcp_registry_does_not_create_transportless_entry(self):
        with patch.dict('os.environ', {}, clear=True):
            command = Codex('/tmp/home', '/tmp').command(None)
        self.assertFalse(any('mcp_servers.' in argument for argument in command))
        with patch.dict('os.environ', {'ORIALIS_CODEX_DISABLED_MCP': 'existing-key'}, clear=True):
            command = Codex('/tmp/home', '/tmp').command(None)
        self.assertIn('mcp_servers."existing-key".enabled=false', command)

    def test_news_publisher_uses_fixed_route_and_stable_idempotency(self):
        response = MagicMock()
        response.__enter__.return_value = response
        response.status = 200
        response.read.return_value = b'{"taskId":"task-1","status":"succeeded"}'
        opener = MagicMock()
        opener.open.return_value = response
        publisher = NewsPublisher("https://news.example/api/v1/agent/ws", "secret")
        payload = {"channel": "github", "kind": "daily", "taskId": "task-1",
                   "generatedAt": "2026-10-03T00:00:00Z",
                   "result": {"repositories": [], "brief": {}}}
        with patch("gateway.build_opener", return_value=opener):
            result = publisher.publish(payload)
        request = opener.open.call_args.args[0]
        body = json.loads(request.data)
        self.assertEqual(request.full_url,
                         "https://news.example/api/v1/news/publish/github/daily")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")
        self.assertEqual(request.get_header("Idempotency-key"), "task-1")
        self.assertEqual(body["source"], "githot.dev")
        self.assertEqual(body["idempotencyKey"], "task-1")
        self.assertEqual(result["status"], "succeeded")

    def test_news_publisher_rejects_unconfigured_and_unsupported_datasets(self):
        with self.assertRaisesRegex(RuntimeError, "not configured"):
            NewsPublisher("", "").publish({})
        publisher = NewsPublisher("https://news.example", "secret")
        with self.assertRaisesRegex(ValueError, "Only GitHub"):
            publisher.publish({"channel": "aihot", "kind": "daily"})

    async def test_news_publish_response_is_replaced_with_server_receipt(self):
        class News:
            def publish(self, payload):
                return {"taskId": payload["taskId"], "status": "succeeded"}
        class PublishingCodex:
            async def run(self, content, thread, on_thread):
                return json.dumps({"type": "news.publish", "requestId": "request-1",
                    "payload": {"taskId": "task-1"}})
        gateway = Gateway(self.store, PublishingCodex(), News())
        await gateway.handle(self.message(), self.send)
        await asyncio.gather(*gateway.tasks)
        reply = next(value for value in self.sent if value["type"] == "message.reply")
        self.assertEqual(json.loads(reply["content"])["type"], "news.publish.ack")
        self.assertEqual(json.loads(reply["content"])["result"]["taskId"], "task-1")


if __name__ == "__main__":
    unittest.main()
