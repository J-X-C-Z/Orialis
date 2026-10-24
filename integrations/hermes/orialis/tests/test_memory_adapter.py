import asyncio
import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import websockets
from gateway.config import Platform

from ..adapter import OrialisAdapter


class MemoryAdapterTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        Platform._add_pseudo_member("orialis")

    async def test_memory_result_bypasses_chat_and_returns_safe_failure(self):
        adapter = OrialisAdapter(SimpleNamespace(extra={}))
        adapter.handle_message = AsyncMock(side_effect=AssertionError("chat handler called"))
        adapter.send = AsyncMock(side_effect=AssertionError("chat send called"))
        adapter._send_wire = AsyncMock()
        request = {"version": 1, "type": "memory.analyze", "request_id": "memory-1", "content": "证据"}
        with patch("integrations.hermes.orialis.memory_analysis.analyze_memory", AsyncMock(return_value={"content": "# 摘要\n\n正文", "category": "ai", "video_status": "none"})):
            await adapter._handle_wire(request)
        self.assertEqual(adapter._send_wire.call_args.args[0], {
            "version": 1, "type": "memory.result", "request_id": "memory-1", "content": "# 摘要\n\n正文", "category": "ai", "video_status": "none",
        })
        self.assertFalse(adapter._reply_anchors)
        self.assertFalse(adapter._active_turn_events)
        self.assertFalse(adapter._processing_status)
        with patch("integrations.hermes.orialis.memory_analysis.analyze_memory", AsyncMock(side_effect=RuntimeError("SECRET_PROVIDER_TOKEN"))):
            await adapter._handle_wire(request)
        failed = adapter._send_wire.call_args.args[0]
        self.assertEqual(failed["type"], "memory.result")
        self.assertNotIn("SECRET", failed["error"])
        self.assertNotIn("content", failed)
        adapter.handle_message.assert_not_called()
        adapter.send.assert_not_called()

    async def test_background_analysis_keeps_reader_free_and_cancels_on_disconnect(self):
        started, pong, cancelled = asyncio.Event(), asyncio.Event(), asyncio.Event()
        frames = []

        async def analyze(content, image=None, source_urls=()):
            started.set()
            try:
                await asyncio.Future()
            finally:
                cancelled.set()

        async def server(socket):
            hello = json.loads(await socket.recv())
            self.assertIn("memory.analyze", hello["capabilities"])
            await socket.send(json.dumps({"version": 1, "type": "hello_ack", "capabilities": ["memory.analyze"]}))
            await socket.send(json.dumps({"version": 1, "type": "memory.analyze", "request_id": "memory-1", "content": "证据"}))
            await started.wait()
            await socket.send(json.dumps({"version": 1, "type": "ping"}))
            async for raw in socket:
                frame = json.loads(raw)
                frames.append(frame)
                if frame["type"] == "pong":
                    pong.set()

        with patch("integrations.hermes.orialis.memory_analysis.analyze_memory", analyze):
            async with websockets.serve(server, "127.0.0.1", 0) as listener:
                port = listener.sockets[0].getsockname()[1]
                adapter = OrialisAdapter(SimpleNamespace(extra={
                    "server_url": f"ws://127.0.0.1:{port}", "device_id": "JXCZ_TEST_Hermes",
                }))
                try:
                    self.assertTrue(await adapter.connect())
                    await asyncio.wait_for(pong.wait(), 3)
                finally:
                    await adapter.disconnect()
                self.assertTrue(cancelled.is_set())
                self.assertFalse(adapter._dispatch_tasks)
                self.assertFalse(any(frame["type"].startswith("message.") for frame in frames))
                self.assertFalse(any(frame["type"] == "memory.result" for frame in frames))
