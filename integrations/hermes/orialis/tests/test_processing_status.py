"""Refresh public lifecycle state without submitting a model turn."""
import asyncio
import json
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock

from gateway.platforms.event import ProcessingOutcome
from gateway.stream_events import ToolCallChunk
from .. import protocol
from . import test_native_transport as transport_tests


class ProcessingStatusTests(unittest.IsolatedAsyncioTestCase):
    setUp = transport_tests.NativeTransportTests.setUp
    asyncTearDown = transport_tests.NativeTransportTests.asyncTearDown

    async def query(self, chat='chat'):
        await self.adapter._handle_wire(protocol.session_request(
            action='info', request_id='refresh', conversation_id=chat, session_id=chat))
        return self.frames[-1]

    async def test_refresh_before_first_token_reports_running_then_real_terminal_outcome(self):
        self.adapter.handle_message = AsyncMock(side_effect=AssertionError('status must not prompt the model'))
        self.assertEqual((await self.query())['status'], 'unknown')
        for outcome, status in [(ProcessingOutcome.SUCCESS, 'completed'), (ProcessingOutcome.FAILURE, 'error')]:
            event = SimpleNamespace(message_id='actual-user', source=SimpleNamespace(chat_id='orialis:chat'))
            await self.adapter.on_processing_start(event)
            self.assertFalse(self.adapter._active_streams)  # No first token or manufactured stream.
            running = await self.query()
            self.assertEqual(running['status'], 'running')
            self.assertEqual(running['request_id'], 'refresh')
            self.assertEqual((await self.query('other'))['status'], 'unknown')
            await self.adapter.on_processing_complete(event, outcome)
            self.assertEqual((await self.query())['status'], status)
        self.adapter.handle_message.assert_not_awaited()

    async def test_public_tool_phase_never_emits_preview_args_or_hidden_thinking(self):
        self.adapter._loop = asyncio.get_running_loop()
        self.adapter._server_capabilities.update({'agent_state', 'tool_state'})
        event = SimpleNamespace(message_id='actual-user', source=SimpleNamespace(chat_id='orialis:chat'))
        await self.adapter.on_processing_start(event)
        secret = 'private-reasoning-and-api-key'
        self.adapter.set_status_text('orialis:chat', secret)
        line = self.adapter.format_tool_event(ToolCallChunk(tool_name='terminal', preview=secret, args={'token': secret}, index=7))
        self.assertEqual(line, '正在调用 terminal')
        self.assertIsNone(self.adapter.format_tool_event(ToolCallChunk(tool_name='_thinking', preview=secret)))
        await asyncio.sleep(0)
        if self.adapter._scheduled_wire_tasks:
            await asyncio.gather(*list(self.adapter._scheduled_wire_tasks))
        self.assertEqual((await self.query())['message'], '正在执行工具')
        self.assertTrue(any(f['type'] == 'tool.started' for f in self.frames))
        self.assertNotIn(secret, json.dumps(self.frames))
        self.adapter.set_status_text('orialis:chat', None)
        self.assertEqual((await self.query())['message'], '正在处理请求')
        await self.adapter.on_processing_complete(event, ProcessingOutcome.CANCELLED)
        self.assertEqual((await self.query())['status'], 'cancelled')

    async def test_old_turn_completion_cannot_overwrite_newer_running_turn(self):
        source = SimpleNamespace(chat_id='orialis:chat')
        old, new = [SimpleNamespace(message_id=i, source=source) for i in ['old', 'new']]
        await self.adapter.on_processing_start(old)
        await self.adapter.on_processing_start(new)
        await self.adapter.on_processing_complete(old, ProcessingOutcome.FAILURE)
        self.assertEqual((await self.query())['status'], 'running')
        await self.adapter.on_processing_complete(new, ProcessingOutcome.SUCCESS)
        self.assertEqual((await self.query())['status'], 'completed')
