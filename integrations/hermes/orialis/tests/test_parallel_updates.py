"""Auxiliary updates never hold up main delivery or outlive their own turn."""
import asyncio
from dataclasses import replace
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from gateway.platforms.event import MessageEvent, ProcessingOutcome
from gateway.stream_events import ToolCallChunk
from .. import adapter as adapter_module
from . import test_native_transport as transport_tests
from . import test_initial_response as initial_tests


class ParallelUpdatesTests(unittest.IsolatedAsyncioTestCase):
    setUp = transport_tests.NativeTransportTests.setUp
    asyncTearDown = transport_tests.NativeTransportTests.asyncTearDown
    event = initial_tests.InitialResponseTests.event

    async def test_blocked_initial_model_does_not_delay_main_start_or_final_or_send_late(self):
        entered, release = asyncio.Event(), asyncio.Event()

        async def blocked(*args):
            entered.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                # A worker may finish after cancellation; the adapter must still suppress it.
                await release.wait()
            return "迟到的首回应"

        with patch.object(adapter_module, "generate_initial_response", new=blocked):
            event = self.event()
            await asyncio.wait_for(self.adapter.on_processing_start(event), .2)
            await asyncio.wait_for(entered.wait(), .2)
            updates = self.adapter._turn_updates[event.message_id]
            result = await asyncio.wait_for(self.adapter.send("orialis:chat", "完整结果"), .2)
            self.assertTrue(result.success)
            release.set()
            await asyncio.sleep(0)
            await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
        replies = [f for f in self.frames if f["type"] == "message.reply"]
        self.assertEqual([f["content"] for f in replies], ["完整结果"])
        self.assertTrue(updates.initial_task.done())

    async def test_initial_ack_wait_does_not_delay_main_final(self):
        sent = asyncio.Event()
        original = self.adapter._send_wire
        self.adapter._orialis = replace(self.adapter._orialis, ack_timeout_seconds=10)

        async def drop_initial_ack(frame):
            if frame.get("message_id", "").startswith("initial_"):
                self.frames.append(frame)
                sent.set()
            else:
                await original(frame)

        self.adapter._send_wire = drop_initial_ack
        event = self.event()
        await asyncio.wait_for(self.adapter.on_processing_start(event), .2)
        await asyncio.wait_for(sent.wait(), .2)
        updates = self.adapter._turn_updates[event.message_id]
        self.assertFalse(updates.initial_task.done())
        self.assertTrue((await asyncio.wait_for(self.adapter.send("orialis:chat", "完整结果"), .2)).success)
        await asyncio.sleep(0)
        self.assertTrue(updates.initial_task.done())
        self.assertFalse(self.adapter._ack_waiters)

    async def test_old_turn_completion_does_not_cancel_new_turn_initial(self):
        release = asyncio.Event()

        async def initial(event, cache):
            if event.message_id == "new-message":
                await release.wait()
            return "自然首回应 " + event.message_id

        with patch.object(adapter_module, "generate_initial_response", new=initial):
            old = self.event("old-message")
            await self.adapter.on_processing_start(old)
            await self.adapter._turn_updates[old.message_id].initial_task
            new = self.event("new-message")
            await self.adapter.on_processing_start(new)
            updates = self.adapter._turn_updates[new.message_id]
            await self.adapter.on_processing_complete(old, ProcessingOutcome.SUCCESS)
            self.assertEqual(self.adapter._processing_status["orialis:chat"]["run_id"], new.message_id)
            self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "running")
            self.assertFalse(updates.initial_task.done())
            release.set()
            await updates.initial_task
        replies = [f for f in self.frames if f["type"] == "message.reply"]
        self.assertEqual(replies[-1]["reply_to"], new.message_id)

    async def test_disconnect_cancels_initial_generation_and_progress_pump(self):
        entered = asyncio.Event()

        async def blocked(*args):
            entered.set()
            await asyncio.Event().wait()

        with patch.object(adapter_module, "generate_initial_response", new=blocked):
            event = self.event()
            await self.adapter.on_processing_start(event)
            updates = self.adapter._turn_updates[event.message_id]
            await asyncio.wait_for(entered.wait(), .2)
            await self.adapter.disconnect()
            await asyncio.sleep(0)
        self.assertTrue(updates.initial_task.done())
        self.assertTrue(updates.task.done())
        self.assertFalse(any(f["type"] == "message.reply" for f in self.frames))

    async def test_body_stream_wins_over_blocked_initial_generation(self):
        entered = asyncio.Event()

        async def blocked(*args):
            entered.set()
            await asyncio.Event().wait()

        with patch.object(adapter_module, "generate_initial_response", new=blocked):
            event = self.event()
            await self.adapter.on_processing_start(event)
            updates = self.adapter._turn_updates[event.message_id]
            await asyncio.wait_for(entered.wait(), .2)
            delivered = await asyncio.wait_for(self.adapter.send_stream_frame(
                "正文正在输出", chat_id="orialis:chat", reply_to=event.message_id,
            ), .2)
            await asyncio.sleep(0)
        self.assertTrue(delivered)
        self.assertTrue(updates.initial_task.done())
        self.assertFalse(any(f.get("message_id", "").startswith("initial_") for f in self.frames))
        self.assertTrue(any(f["type"] == "agent.delta" for f in self.frames))

    async def test_progress_ack_wait_does_not_delay_main_final(self):
        sent = asyncio.Event()
        original = self.adapter._send_wire
        self.adapter._orialis = replace(self.adapter._orialis, ack_timeout_seconds=10)
        event = self.event()
        await self.adapter.on_processing_start(event)
        updates = self.adapter._turn_updates[event.message_id]
        await updates.initial_task
        updates.last_public -= 31
        updates.observe("tool", "web_search")

        async def drop_progress_ack(frame):
            if frame.get("message_id", "").startswith("progress_"):
                self.frames.append(frame)
                sent.set()
            else:
                await original(frame)

        self.adapter._send_wire = drop_progress_ack
        reporting = asyncio.create_task(updates.report())
        try:
            await asyncio.wait_for(sent.wait(), .2)
            self.assertFalse(reporting.done())
            self.assertTrue((await asyncio.wait_for(self.adapter.send("orialis:chat", "完整结果"), .2)).success)
        finally:
            reporting.cancel()
            await asyncio.gather(reporting, return_exceptions=True)
        self.assertFalse(self.adapter._ack_waiters)

    async def test_socket_receive_failure_cancels_updates_before_reconnect(self):
        entered = asyncio.Event()

        async def blocked(*args):
            entered.set()
            await asyncio.Event().wait()

        with patch.object(adapter_module, "generate_initial_response", new=blocked):
            event = self.event()
            await self.adapter.on_processing_start(event)
            updates = self.adapter._turn_updates[event.message_id]
            await asyncio.wait_for(entered.wait(), .2)
            self.adapter._ws = SimpleNamespace(
                recv=AsyncMock(side_effect=ConnectionError("test socket dropped")), close=AsyncMock(),
            )
            with patch.object(self.adapter, "_schedule_reconnect") as reconnect, self.assertLogs(
                adapter_module.logger, level="ERROR"
            ):
                await self.adapter._receive_loop()
                reconnect.assert_called_once()
            await asyncio.sleep(0)
        self.assertTrue(updates.closed)
        self.assertTrue(updates.initial_task.done())
        self.assertTrue(updates.task.done())
        self.assertFalse(self.adapter._turn_updates)
        self.assertFalse(any(f["type"] == "message.reply" for f in self.frames))

    async def test_worker_tool_phase_uses_its_own_chat_over_another_active_stream(self):
        first = self.event("first-message")
        await self.adapter.on_processing_start(first)
        first_updates = self.adapter._turn_updates[first.message_id]
        await first_updates.initial_task
        self.adapter._stream_context = {
            "chat_id": "orialis:chat", "conversation_id": "chat", "turn_id": "first-stream",
        }
        source = self.adapter.build_source(
            chat_id="orialis:other-chat", chat_type="dm", user_id="test-device", message_id="second-message",
        )
        second = MessageEvent(text="查找资料", source=source, message_id="second-message",
                              raw_message={"type": "message.send"})
        await self.adapter.on_processing_start(second)
        second_updates = self.adapter._turn_updates[second.message_id]
        self.adapter.format_tool_event(ToolCallChunk(tool_name="web_search"))
        await asyncio.sleep(0)
        self.assertEqual(first_updates.phase, ("processing", ""))
        self.assertEqual(second_updates.phase, ("tool", "查找资料"))

    async def test_setup_and_system_notices_do_not_suppress_natural_initial_but_main_text_does(self):
        entered, release = asyncio.Event(), asyncio.Event()

        async def initial(*args):
            entered.set()
            await release.wait()
            return "我先核对这份资料，再给你完整结果。"

        with patch.object(adapter_module, "generate_initial_response", new=initial):
            event = self.event()
            await self.adapter.on_processing_start(event)
            updates = self.adapter._turn_updates[event.message_id]
            await asyncio.wait_for(entered.wait(), .2)
            for text, metadata in [
                ("📬 No home channel is set for Orialis. A home channel delivers scheduled results.", None),
                ("✅", None),
                ("系统状态通知", {"non_conversational": True}),
            ]:
                self.assertTrue((await self.adapter.send("orialis:chat", text, metadata=metadata)).success)
                await asyncio.sleep(0)
                self.assertFalse(updates.initial_task.done())
                self.assertFalse(updates.paused)
                self.assertFalse(updates.closed)
            release.set()
            await updates.initial_task
            initial_frames = [frame for frame in self.frames
                              if frame.get("message_id", "").startswith("initial_")]
            self.assertEqual(len(initial_frames), 1)
            self.assertIn("核对这份资料", initial_frames[0]["content"])
            self.assertTrue((await self.adapter.send("orialis:chat", "这是实际正文")).success)
            await asyncio.sleep(0)
            self.assertTrue(updates.paused)
            self.assertTrue(updates.task.done())

    async def test_blocked_contextual_summary_never_blocks_final_and_late_result_is_dropped(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def summarize(*args):
            entered.set()
            try:
                await release.wait()
            except asyncio.CancelledError:
                # A worker response may arrive after cancellation; it still must be ignored.
                await release.wait()
            return '迟到的任务进度摘要'
        with patch.object(adapter_module, 'generate_progress_response', new=summarize), patch(
            'integrations.hermes.orialis.turn_updates.PROGRESS_INTERVAL', .001
        ):
            event = self.event()
            await self.adapter.on_processing_start(event)
            updates = self.adapter._turn_updates[event.message_id]
            await updates.initial_task
            updates.last_public -= 31
            updates.observe('tool', 'web_search')
            await asyncio.wait_for(entered.wait(), .2)
            self.assertTrue((await asyncio.wait_for(self.adapter.send(
                'orialis:chat', '完整结果', metadata={'notify': True}
            ), .2)).success)
            self.assertTrue(updates.closed)
            release.set()
            await asyncio.wait_for(asyncio.gather(updates.task, return_exceptions=True), .2)
            await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
        self.assertFalse(any(f.get('content') == '迟到的任务进度摘要' for f in self.frames))
        self.assertEqual([f['content'] for f in self.frames if f['type']=='message.reply'][-1], '完整结果')
