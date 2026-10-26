"""Background side messages must never become dependencies of the real turn."""
import asyncio
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

from .. import turn_updates
from ..turn_updates import TurnUpdates


class TurnUpdatesTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.now = 0.0
        self.clock = patch.object(turn_updates, "time", SimpleNamespace(monotonic=lambda: self.now))
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.updates = []

    async def asyncTearDown(self):
        for update in self.updates:
            update.close()
        await asyncio.gather(
            *(task for update in self.updates for task in (update.initial_task, update.task)),
            return_exceptions=True,
        )

    def start(self, initial=None, emit=None, summarize=None):
        async def generated(facts):
            if facts['phase'] == 'tool':
                return f"模型生成的摘要：{facts['activity']}，调用尚未返回。"
            if facts['phase'] == 'returned':
                return "模型根据工具已返回的事实说明当前进展。"
            return "模型说明请求仍在处理中，当前没有新增结果。"
        update = TurnUpdates(initial or AsyncMock(), emit or AsyncMock(),
                             summarize or AsyncMock(side_effect=generated))
        update.public_notes = ["已确认请求的第一项事实，正在核对下一项。"]
        self.updates.append(update)
        return update

    async def test_blocked_opening_does_not_stop_real_work_and_real_output_cancels_it(self):
        entered, release = asyncio.Event(), asyncio.Event()
        sent = []

        async def initial():
            entered.set()
            await release.wait()
            sent.append("late opening")

        update = self.start(initial)
        await entered.wait()
        # This is the real turn's independent work, not a timeout of the opening.
        main_result = await asyncio.wait_for(asyncio.sleep(0, result="complete answer"), .1)
        self.assertEqual(main_result, "complete answer")
        self.assertFalse(update.initial_task.done())
        update.public_output()
        await asyncio.gather(update.initial_task, return_exceptions=True)
        release.set()
        await asyncio.sleep(0)
        self.assertTrue(update.initial_task.cancelled())
        self.assertEqual(sent, [])

    async def test_report_uses_generated_text_and_only_supplies_observed_public_facts(self):
        emit = AsyncMock()
        summarize = AsyncMock(side_effect=["先核对高铁和自驾各自的耗时，资料还在返回中。", "相关查询已返回，我接着整理适合周末出行的比较。"])
        update = self.start(emit=emit, summarize=summarize)
        self.now = 31
        update.observe("tool", "web_search")
        await update.report()
        self.assertEqual(emit.await_args.args[0], "先核对高铁和自驾各自的耗时，资料还在返回中。")
        facts = summarize.await_args.args[0]
        self.assertEqual(facts['phase'], 'tool')
        self.assertEqual(facts['activity'], '查找资料')
        self.assertEqual(facts['stage_history'], [{'phase': 'tool', 'activity': '查找资料'}])
        self.assertEqual(facts['public_notes'], ['已确认请求的第一项事实，正在核对下一项。'])
        self.now = 62
        update.public_notes.append("已确认第二项事实。")
        update.observe("returned")
        await update.report()
        self.assertEqual(emit.await_args.args[0], "相关查询已返回，我接着整理适合周末出行的比较。")
        self.assertEqual(summarize.await_args.args[0]['phase'], 'returned')
        self.assertEqual(summarize.await_args.args[0]['previous_updates'], ["先核对高铁和自驾各自的耗时，资料还在返回中。"])
        self.assertEqual(emit.await_count, 2)

    async def test_missing_or_failed_summary_never_sends_a_template_and_can_retry(self):
        emit = AsyncMock()
        summarize = AsyncMock(side_effect=[None, RuntimeError('auxiliary failed'), '现在继续核对相关材料。'])
        update = self.start(emit=emit, summarize=summarize)
        self.now = 31
        await update.report()
        emit.assert_not_awaited()
        self.now = 45
        await update.report()
        self.assertEqual(summarize.await_count, 1)
        self.now = 62
        with self.assertLogs(turn_updates.logger, level='WARNING'):
            await update.report()
        emit.assert_not_awaited()
        self.now = 93
        await update.report()
        self.assertEqual(emit.await_args.args[0], '现在继续核对相关材料。')
        self.now = 124
        await update.report()
        self.assertEqual(summarize.await_count, 3)
        self.assertEqual(emit.await_count, 1)

    async def test_no_facts_or_unchanged_facts_never_call_summary_model(self):
        model, emit = AsyncMock(return_value='新发现对目标有帮助。'), AsyncMock()
        update = self.start(emit=emit, summarize=model)
        update.public_notes = []
        self.now = 31
        update.observe('tool', 'web_search')
        await update.report()
        model.assert_not_awaited()
        update.public_notes = ['已确认高铁比自驾快。']
        await update.report()
        model.assert_awaited_once()
        self.now = 62
        update.observe('returned')
        await update.report()
        model.assert_awaited_once()  # A stage change alone adds no finding.
        update.public_output('停车费用已核实，自驾仍然更贵。')
        update.observe('tool', 'read_file')
        self.now = 93
        await update.report()
        self.assertEqual(model.await_count, 2)

    async def test_no_generator_means_no_fixed_fallback(self):
        emit = AsyncMock()
        update = TurnUpdates(AsyncMock(), emit)
        self.updates.append(update)
        self.now = 31
        await update.report()
        emit.assert_not_awaited()

    async def test_only_one_summary_in_flight_and_phase_change_discards_stale_result(self):
        entered, release = asyncio.Event(), asyncio.Event()
        emit = AsyncMock()
        async def summarize(facts):
            entered.set()
            await release.wait()
            return '正在检索旧阶段的资料。'
        model = AsyncMock(side_effect=summarize)
        update = self.start(emit=emit, summarize=model)
        update.observe('tool', 'web_search')
        self.now = 31
        pending = asyncio.create_task(update.report())
        try:
            await entered.wait()
            await update.report()
            self.assertEqual(model.await_count, 1)
            update.observe('returned')
            release.set()
            await pending
            emit.assert_not_awaited()
            self.assertFalse(update._reporting)
        finally:
            pending.cancel()
            await asyncio.gather(pending, return_exceptions=True)

    async def test_public_notes_and_history_are_passed_without_inventing_findings(self):
        summarize = AsyncMock(return_value='已确认入口逻辑，接着查看相邻代码。')
        update = self.start(summarize=summarize)
        update.public_output('已经确认入口位于 adapter.py。')
        update.observe('tool', 'read_file')
        self.now = 31
        await update.report()
        facts = summarize.await_args.args[0]
        self.assertEqual(facts['public_notes'][-1], '已经确认入口位于 adapter.py。')
        self.assertEqual(facts['stage_history'], [{'phase': 'tool', 'activity': '查看文件和资料'}])
        self.assertNotIn('result', facts)
        self.assertNotIn('args', facts)
        self.assertNotIn('reasoning', facts)

    async def test_throttle_coalesces_state_and_does_not_repeat_unchanged_status(self):
        emit = AsyncMock()
        update = self.start(emit=emit)
        update.observe("tool", "web_search")
        self.now = 29.9
        await update.report()
        emit.assert_not_awaited()
        # The latest true state supersedes earlier queued status before the interval.
        update.observe("tool", "read_file")
        self.now = 30
        await update.report()
        self.assertIn("查看文件和资料", emit.await_args.args[0])
        self.assertEqual(emit.await_args.args[1], 1)
        self.now = 100
        await update.report()
        self.assertEqual(emit.await_count, 1)
        update.public_notes.append("已确认第二项事实。")
        update.observe("returned")
        await update.report()
        self.assertEqual(emit.await_count, 2)
        self.assertEqual(emit.await_args.args[1], 2)

    async def test_public_text_pauses_local_updates_until_a_new_tool_stage(self):
        emit = AsyncMock()
        update = self.start(emit=emit)
        update.public_output()
        self.now = 50
        await update.report()
        emit.assert_not_awaited()
        update.observe("tool", "terminal")
        await update.report()
        self.assertIn("执行任务步骤", emit.await_args.args[0])
        self.assertEqual(emit.await_count, 1)

    async def test_opening_receipt_resets_progress_interval_without_waiting_for_another_phase(self):
        emit = AsyncMock()
        update = self.start(emit=emit)
        self.now = 12
        update.initial_sent()
        self.now = 41
        await update.report()
        emit.assert_not_awaited()
        self.now = 42
        await update.report()
        self.assertEqual(emit.await_count, 1)
        self.assertIn("仍在处理中", emit.await_args.args[0])

    async def test_close_cancels_a_blocked_progress_delivery_and_prevents_late_messages(self):
        entered, release = asyncio.Event(), asyncio.Event()
        delivered = []

        async def emit(text, sequence):
            entered.set()
            await release.wait()
            delivered.append(text)

        with patch.object(turn_updates, "PROGRESS_INTERVAL", .001):
            update = self.start(emit=emit)
            self.now = 1
            await asyncio.wait_for(entered.wait(), .2)
            update.close()
            await asyncio.gather(update.task, return_exceptions=True)
        release.set()
        self.now = 100
        update.observe("tool", "web_search")
        await update.report()
        await asyncio.sleep(0)
        self.assertTrue(update.task.cancelled())
        self.assertTrue(update.closed)
        self.assertEqual(delivered, [])

    async def test_a_closed_turn_does_not_change_a_new_turn(self):
        old_emit, new_emit = AsyncMock(), AsyncMock()
        old = self.start(emit=old_emit)
        new = self.start(emit=new_emit)
        old.close()
        self.now = 31
        old.observe("tool", "read_file")
        new.observe("tool", "web_search")
        await old.report()
        await new.report()
        old_emit.assert_not_awaited()
        new_emit.assert_awaited_once()
        self.assertIn("查找资料", new_emit.await_args.args[0])

    async def test_real_pump_cancels_pending_emit_on_public_text_and_resumes_only_for_new_work(self):
        entered, release, resumed = asyncio.Event(), asyncio.Event(), asyncio.Event()
        delivered = []

        async def emit(text, sequence):
            if sequence == 1:
                entered.set()
                await release.wait()
            else:
                delivered.append(text)
                resumed.set()

        with patch.object(turn_updates, "PROGRESS_INTERVAL", .001):
            update = self.start(emit=emit)
            update.observe("tool", "web_search")
            self.now = 1
            await asyncio.wait_for(entered.wait(), .2)
            old_pump = update.task
            update.public_output()
            await asyncio.gather(old_pump, return_exceptions=True)
            release.set()
            await asyncio.sleep(.005)
            self.assertTrue(old_pump.cancelled())
            self.assertEqual(delivered, [])

            # A new actual tool phase, not mere time passing, resumes reporting.
            self.now = 2
            update.observe("tool", "read_file")
            self.assertIsNot(update.task, old_pump)
            await asyncio.wait_for(resumed.wait(), .2)
            self.assertEqual(len(delivered), 1)
            self.assertIn("查看文件和资料", delivered[0])
            update.close()  # The real final response makes this permanent.
            self.now = 3
            update.observe("returned")
            await asyncio.sleep(.005)
            self.assertEqual(len(delivered), 1)

    async def test_cancellation_ignoring_old_pump_exits_when_a_new_tool_stage_replaces_it(self):
        entered, release, resumed = asyncio.Event(), asyncio.Event(), asyncio.Event()
        emit = AsyncMock()
        async def summarize(facts):
            if facts['activity'] == '查找资料':
                entered.set()
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    await release.wait()
                return '旧的检索阶段摘要'
            resumed.set()
            return '继续查看刚获得的文件内容。'
        with patch.object(turn_updates, 'PROGRESS_INTERVAL', .001):
            update = self.start(emit=emit, summarize=summarize)
            update.observe('tool', 'web_search')
            self.now = 1
            await asyncio.wait_for(entered.wait(), .2)
            old_pump = update.task
            update.public_output('已经定位资料入口。')
            # Deliver cancellation before creating the replacement, emulating a slow SDK callback.
            await asyncio.sleep(0)
            update.observe('tool', 'read_file')
            self.assertIsNot(update.task, old_pump)
            release.set()
            self.now = 2
            try:
                await asyncio.wait_for(asyncio.gather(old_pump, return_exceptions=True), .2)
                await asyncio.wait_for(resumed.wait(), .2)
                self.assertFalse(any(call.args[0] == '旧的检索阶段摘要' for call in emit.await_args_list))
            finally:
                old_pump.cancel()
                await asyncio.gather(old_pump, return_exceptions=True)

    async def test_public_body_invalidates_old_summary_even_when_same_phase_resumes(self):
        entered, release, resumed = asyncio.Event(), asyncio.Event(), asyncio.Event()
        emit = AsyncMock()
        calls = 0
        async def summarize(facts):
            nonlocal calls
            calls += 1
            if calls == 1:
                entered.set()
                try:
                    await release.wait()
                except asyncio.CancelledError:
                    await release.wait()
                return '正文出来前生成的旧摘要'
            resumed.set()
            return '根据新一轮状态继续核对资料。'
        with patch.object(turn_updates, 'PROGRESS_INTERVAL', .001):
            update = self.start(emit=emit, summarize=summarize)
            update.observe('tool', 'web_search')
            self.now = 1
            await asyncio.wait_for(entered.wait(), .2)
            old_pump, old_revision = update.task, update.revision
            update.public_output()  # Ordinary body output has no Commentary note.
            self.assertGreater(update.revision, old_revision)
            body_revision = update.revision
            await asyncio.sleep(0)  # Let the slow callback swallow its cancellation.
            update.observe('tool', 'web_search')  # No phase change to invalidate it for us.
            self.assertEqual(update.revision, body_revision)
            self.assertIsNot(update.task, old_pump)
            release.set()
            self.now = 2
            try:
                await asyncio.wait_for(asyncio.gather(old_pump, return_exceptions=True), .2)
                await asyncio.wait_for(resumed.wait(), .2)
                self.assertTrue(old_pump.done())
                self.assertEqual([call.args[0] for call in emit.await_args_list],
                                 ['根据新一轮状态继续核对资料。'])
                self.assertEqual(calls, 2)
            finally:
                old_pump.cancel()
                await asyncio.gather(old_pump, return_exceptions=True)


from gateway.platforms.event import ProcessingOutcome
from gateway.stream_consumer import GatewayStreamConsumer
from gateway.stream_events import ToolCallChunk
from . import test_initial_response as initial_tests
from . import test_native_transport as transport_tests


class AdapterProgressPhaseTests(unittest.IsolatedAsyncioTestCase):
    setUp = transport_tests.NativeTransportTests.setUp
    asyncTearDown = transport_tests.NativeTransportTests.asyncTearDown
    event = initial_tests.InitialResponseTests.event

    async def test_worker_phase_callbacks_and_native_commentary_keep_turn_open_until_final(self):
        self.adapter._server_capabilities.update({"agent_state", "tool_state"})
        event = self.event()
        await self.adapter.on_processing_start(event)
        updates = self.adapter._turn_updates[event.message_id]
        await updates.initial_task

        def worker_status():
            self.adapter.set_status_text("orialis:chat", "private tool argument")
            self.adapter.format_tool_event(ToolCallChunk(
                tool_name="web_search", preview="private tool argument", index=1,
            ))

        await asyncio.to_thread(worker_status)
        await asyncio.sleep(0)
        self.assertEqual(updates.phase, ("tool", "查找资料"))
        consumer = GatewayStreamConsumer(self.adapter, "orialis:chat", initial_reply_to_id=event.message_id)
        await consumer._deliver_commentary("已经找到相关资料，接下来核对来源并整理结论。")
        self.assertFalse(updates.closed)
        self.assertTrue(updates.paused)
        self.assertFalse(any(frame["type"] == "agent.complete" for frame in self.frames))
        self.assertEqual(self.adapter._processing_status["orialis:chat"]["status"], "running")

        await asyncio.to_thread(self.adapter.set_status_text, "orialis:chat", None)
        await asyncio.sleep(0)
        self.assertEqual(updates.phase, ("returned", ""))
        self.assertFalse(updates.paused)
        self.assertTrue(await self.adapter.send_stream_frame(
            "完整结果", chat_id="orialis:chat", reply_to=event.message_id,
            turn_id="native-final", finalize=True, is_turn_final=True,
        ))
        self.assertTrue(updates.closed)
        await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
        replies = [frame for frame in self.frames if frame["type"] == "message.reply"]
        self.assertEqual(replies[-1]["content"], "完整结果")
        self.assertFalse(any("private tool argument" in str(frame) for frame in self.frames))
        final_index = next(i for i, frame in enumerate(self.frames)
                           if frame.get("content") == "完整结果" and frame["type"] == "message.reply")
        complete_indices = [i for i, frame in enumerate(self.frames) if frame["type"] == "agent.complete"]
        self.assertTrue(complete_indices)
        self.assertGreater(min(complete_indices), final_index)

    async def test_tool_chrome_does_not_mute_progress_but_returned_body_and_final_do(self):
        self.adapter._server_capabilities.update({"agent_state", "tool_state"})
        event = self.event()
        await self.adapter.on_processing_start(event)
        updates = self.adapter._turn_updates[event.message_id]
        await updates.initial_task

        def tool_started():
            self.adapter.set_status_text("orialis:chat", "private status preview")
            self.adapter.format_tool_event(ToolCallChunk(tool_name="terminal", index=2))

        await asyncio.to_thread(tool_started)
        await asyncio.sleep(0)
        self.assertEqual(updates.phase, ("tool", "执行任务步骤"))
        pump = updates.task
        self.assertTrue(await self.adapter.send_stream_frame(
            "正在调用 terminal", chat_id="orialis:chat", reply_to=event.message_id,
            turn_id="chrome", finalize=False,
        ))
        self.assertFalse(updates.paused)
        self.assertIs(updates.task, pump)
        self.assertFalse(pump.done())
        self.assertFalse(pump.cancelling())
        updates.public_notes = ["已确认请求的一部分，继续处理剩余步骤。"]
        updates.last_public -= 31
        await updates.report()
        progress = [frame for frame in self.frames
                    if str(frame.get("message_id", "")).startswith("progress_")]
        self.assertEqual(len(progress), 1)
        self.assertIn("执行任务步骤", progress[0]["content"])
        self.assertIn("尚未返回", progress[0]["content"])
        self.assertFalse(any(frame["type"] == "agent.complete" for frame in self.frames))

        await asyncio.to_thread(self.adapter.set_status_text, "orialis:chat", None)
        await asyncio.sleep(0)
        self.assertEqual(updates.phase, ("returned", ""))
        self.assertTrue(await self.adapter.send_stream_frame(
            "现在开始整理完整结果", chat_id="orialis:chat", reply_to=event.message_id,
            turn_id="body", finalize=False,
        ))
        self.assertTrue(updates.paused)
        self.assertTrue(pump.cancelling())
        updates.last_public -= 31
        await updates.report()
        self.assertEqual(sum(str(frame.get("message_id", "")).startswith("progress_")
                             for frame in self.frames), 1)
        self.assertTrue(await self.adapter.send_stream_frame(
            "现在开始整理完整结果：已经完成。", chat_id="orialis:chat", reply_to=event.message_id,
            turn_id="body", finalize=True, is_turn_final=True,
        ))
        self.assertTrue(updates.closed)
        await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)
