"""A durable initial response must not finish the Hermes processing lifecycle."""
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

from gateway.platforms.event import MessageEvent, ProcessingOutcome
from gateway.stream_consumer import GatewayStreamConsumer
from .. import protocol
from . import test_native_transport as transport_tests


class InitialResponseTests(unittest.IsolatedAsyncioTestCase):
    setUp = transport_tests.NativeTransportTests.setUp
    asyncTearDown = transport_tests.NativeTransportTests.asyncTearDown

    def event(self, message_id="user-message", text="请分析这份资料", kind="message.send"):
        source = self.adapter.build_source(
            chat_id="orialis:chat", chat_type="dm", user_id="test-device",
            message_id=message_id,
        )
        return MessageEvent(
            text=text, source=source, message_id=message_id,
            raw_message={"type": kind},
        )

    async def test_initial_reply_precedes_processing_and_only_completion_ends_turn(self):
        self.adapter._server_capabilities.add("agent_state")
        event = self.event()
        await self.adapter.on_processing_start(event)
        initial = next(f for f in self.frames if f["type"] == "message.reply")
        self.assertEqual(initial["content"], "收到，我先处理一下。")
        self.assertEqual(initial["reply_to"], event.message_id)
        self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "running")
        self.assertFalse(any(f["type"] == "agent.complete" for f in self.frames))

        # Model work happens after the initial response receipt, with its anchor intact.
        self.assertEqual(self.adapter._reply_anchor("orialis:chat"), event.message_id)
        result = await self.adapter.send("orialis:chat", "分析完成，这是完整结果。")
        self.assertTrue(result.success)
        replies = [f for f in self.frames if f["type"] == "message.reply"]
        self.assertEqual(len(replies), 2)
        self.assertNotEqual(replies[0]["message_id"], replies[1]["message_id"])
        self.assertEqual(replies[1]["reply_to"], event.message_id)
        self.assertFalse(any(f["type"] == "agent.complete" for f in self.frames))
        await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
        self.assertEqual(self.frames[-1]["type"], "agent.complete")
        self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "completed")

    async def test_same_input_reuses_initial_id_but_distinct_inputs_do_not(self):
        ids = []
        for anchor in ["user-message", "user-message", "next-message"]:
            await self.adapter.on_processing_start(self.event(anchor))
            ids.append(self.frames[-1]["message_id"])
        self.assertEqual(ids[0], ids[1])
        self.assertNotEqual(ids[1], ids[2])

    async def test_commands_legacy_peers_and_background_inputs_have_no_initial_reply(self):
        for event in [self.event(text="/stop"), self.event(kind="command.request"),
                      self.event(kind="delivery.send")]:
            await self.adapter.on_processing_start(event)
        self.adapter._server_capabilities.remove("reply_followups")
        await self.adapter.on_processing_start(self.event())
        self.assertFalse(any(f["type"] == "message.reply" for f in self.frames))

    async def test_initial_receipt_timeout_does_not_prevent_final_reply(self):
        original = self.adapter._send_wire

        async def drop_initial_receipt(frame):
            if frame.get("message_id", "").startswith("initial_"):
                self.frames.append(frame)
            else:
                await original(frame)

        self.adapter._send_wire = drop_initial_receipt
        await self.adapter.on_processing_start(self.event())
        self.assertFalse(self.adapter._ack_waiters)
        self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "running")
        self.assertTrue((await self.adapter.send("orialis:chat", "完整结果")).success)

    async def test_rejected_initial_reply_does_not_clear_active_turn(self):
        self.reply_status = "rejected"
        await self.adapter.on_processing_start(self.event())
        self.assertIn("user-message", self.adapter._active_turn_events)
        self.assertEqual(self.adapter._reply_anchor("orialis:chat"), "user-message")
        self.reply_status = "received"
        self.assertTrue((await self.adapter.send("orialis:chat", "完整结果")).success)

    async def test_correlated_rejection_retries_the_same_initial_id_without_waiting_for_timeout(self):
        original = self.adapter._send_wire
        rejected = []

        async def reject_once(frame):
            if frame.get("message_id", "").startswith("initial_") and not rejected:
                rejected.append(frame["message_id"])
                self.frames.append(frame)
                await self.adapter._handle_wire(protocol.error(
                    "REPLY_REJECTED", "temporary persistence contention", reply_to=frame["message_id"],
                ))
            else:
                await original(frame)

        self.adapter._send_wire = reject_once
        await self.adapter.on_processing_start(self.event())
        replies = [f for f in self.frames if f["type"] == "message.reply"]
        self.assertEqual(len(replies), 2)
        self.assertEqual(replies[0]["message_id"], replies[1]["message_id"])
        self.assertFalse(self.adapter._ack_waiters)

    async def test_empty_native_placeholder_does_not_finish_before_real_final(self):
        self.adapter._server_capabilities.add("agent_state")
        event = self.event()
        await self.adapter.on_processing_start(event)
        consumer = GatewayStreamConsumer(self.adapter, "orialis:chat", initial_reply_to_id=event.message_id)
        await consumer._send_frame("", finalize=False)
        consumer._native_stream_opened = True
        await consumer._send_or_edit("", finalize=True)
        replies = [f for f in self.frames if f["type"] == "message.reply"]
        self.assertEqual([f["content"] for f in replies], ["收到，我先处理一下。"])
        self.assertFalse(any(f["type"] == "agent.complete" for f in self.frames))
        self.assertTrue((await self.adapter.send("orialis:chat", "完整结果")).success)
        await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
        self.assertEqual(self.frames[-1]["type"], "agent.complete")

    async def test_real_literal_checkmark_answer_survives_native_transport_fallback(self):
        consumer = GatewayStreamConsumer(self.adapter, "orialis:chat", initial_reply_to_id="user-message")
        self.assertTrue(await consumer._send_or_edit("✅", finalize=True))
        replies = [f for f in self.frames if f["type"] == "message.reply"]
        self.assertEqual([f["content"] for f in replies], ["✅"])

    async def test_startup_queued_event_stays_running_until_its_replay_finishes(self):
        self.adapter._server_capabilities.add("agent_state")
        event = self.event()
        runner = SimpleNamespace(_startup_restore_queue=[])
        self.adapter.gateway_runner = runner
        await self.adapter.on_processing_start(event)
        runner._startup_restore_queue.append(event)
        with patch("gateway.platforms.base.BasePlatformAdapter.on_processing_complete", new_callable=AsyncMock) as complete:
            await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
            complete.assert_not_awaited()
            self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "running")
            self.assertEqual(self.adapter._reply_anchor("orialis:chat"), event.message_id)
            self.assertIn(event.message_id, self.adapter._active_turn_events)
            self.assertFalse(any(f["type"] == "agent.complete" for f in self.frames))

            replay = runner._startup_restore_queue.pop(0)
            self.assertIs(replay, event)
            replay._hermes_startup_restore_replay = True
            await self.adapter.on_processing_start(replay)
            self.assertTrue((await self.adapter.send("orialis:chat", "重放处理后的完整结果")).success)
            await self.adapter.on_processing_complete(replay, ProcessingOutcome.SUCCESS)
            complete.assert_awaited_once_with(replay, ProcessingOutcome.SUCCESS)
        self.assertEqual(self.frames[-1]["type"], "agent.complete")
        self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "completed")

    async def test_startup_queue_does_not_hide_completion_of_a_distinct_equal_event(self):
        self.adapter._server_capabilities.add("agent_state")
        event = self.event()
        self.adapter.gateway_runner = SimpleNamespace(_startup_restore_queue=[self.event()])
        await self.adapter.on_processing_start(event)
        await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
        self.assertEqual(self.frames[-1]["type"], "agent.complete")
