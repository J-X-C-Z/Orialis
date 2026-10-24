"""Exercise Hermes' installed blocking primitives; only transport is captured."""
import asyncio
import json
import os
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

from gateway.config import Platform
from gateway.platforms.base import SendResult
from tools import approval, clarify_gateway
from tools.clarify_tool import _clean_answer

from ..adapter import OrialisAdapter
from .. import protocol


class NativeInteractionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {'HERMES_HOME': self.home.name})
        self.environment.start()
        self.session = 'orialis-native-test-' + uuid.uuid4().hex
        Platform._add_pseudo_member('orialis')
        self.adapter = OrialisAdapter(SimpleNamespace(extra={}))
        self.adapter._negotiated = True
        self.adapter._server_capabilities = {'approval', 'clarify'}
        self.adapter._ws = object()
        self.adapter._running = True
        self.requests, self.responses = [], []

        async def send_wire(frame):
            self.responses.append(frame)
            if frame.get('event_id'):
                self.requests.append(frame)
                # The real Rust transport acknowledges event_id/seq, never request_id.
                await self.adapter._handle_wire({'version': 1, 'type': 'agent.ack',
                    'event_id': frame['event_id'], 'seq': frame['seq'], 'status': 'received'})

        self.adapter._send_wire = send_wire

    async def asyncTearDown(self):
        approval.resolve_gateway_approval(self.session, 'deny', resolve_all=True)
        clarify_gateway.clear_session(self.session)
        self.environment.stop()
        self.home.cleanup()

    async def test_multi_select_structured_event_resumes_real_waiter_with_distinct_labels(self):
        request_id = 'clarify-' + uuid.uuid4().hex
        choices = ['contains, comma', 'second']
        clarify_gateway.register(request_id, self.session, 'Choose', choices, multi_select=True)
        marker = Path(self.home.name, 'clarify-resumed.json')

        def task():
            response = clarify_gateway.wait_for_response(request_id, timeout=5)
            answer = _clean_answer(response, True)
            marker.write_text(json.dumps(answer), encoding='utf-8')
            return answer

        waiter = asyncio.create_task(asyncio.to_thread(task))
        sent = await self.adapter.send_clarify('orialis:chat-1', 'Choose', choices, request_id, self.session)
        self.assertTrue(sent.success)
        self.assertEqual(self.requests[-1]['type'], 'clarify.request')
        self.assertTrue(self.requests[-1]['multi_select'])
        self.assertFalse(marker.exists())
        await self.adapter._handle_wire(protocol.clarify_response(
            request_id=request_id, conversation_id='chat-1', response=json.dumps(choices)))
        self.assertEqual(await asyncio.wait_for(waiter, timeout=2), choices)
        self.assertEqual(json.loads(marker.read_text()), choices)
        self.assertEqual(self.responses[-1]['status'], 'resolved')

    async def test_cancel_returns_native_sentinel_without_executing_continuation(self):
        request_id = 'cancel-' + uuid.uuid4().hex
        clarify_gateway.register(request_id, self.session, 'Continue?', ['yes'])
        marker = Path(self.home.name, 'must-not-exist.txt')

        def task():
            response = clarify_gateway.wait_for_response(request_id, timeout=5)
            if response != clarify_gateway.CANCELLED:
                marker.write_text('unexpected continuation')
            return response

        waiter = asyncio.create_task(asyncio.to_thread(task))
        await self.adapter.send_clarify('orialis:chat-1', 'Continue?', ['yes'], request_id, self.session)
        await self.adapter._handle_wire(protocol.clarify_cancel(
            request_id=request_id, conversation_id='chat-1', reason='cancelled'))
        self.assertEqual(await asyncio.wait_for(waiter, timeout=2), clarify_gateway.CANCELLED)
        self.assertFalse(marker.exists())

    async def test_parallel_native_approvals_bind_exact_request_ids_and_resume_only_selected_task(self):
        queued = {}
        markers = [Path(self.home.name, f'approval-{index}.txt') for index in range(2)]
        commands = ['echo approval-one', 'echo approval-two']

        def task(index, ready):
            def notify(data):
                queued[index] = data
                ready.set()

            result = approval._await_gateway_decision(self.session, notify, {
                'command': commands[index], 'description': 'Harmless test marker',
                'pattern_key': f'orialis-test-{index}', 'pattern_keys': [f'orialis-test-{index}'],
            })
            if result.get('choice') == 'once':
                markers[index].write_text('continued after approval')
            return result

        waiters = []
        for index in range(2):
            ready = threading.Event()
            waiters.append(asyncio.create_task(asyncio.to_thread(task, index, ready)))
            self.assertTrue(await asyncio.to_thread(ready.wait, 3))
        unmatched = await self.adapter.send_exec_approval(
            'orialis:chat-1', 'echo not-pending', self.session, description='Harmless test marker')
        self.assertFalse(unmatched.success)
        self.assertEqual(self.requests, [])
        for index in (1, 0):
            sent = await self.adapter.send_exec_approval(
                'orialis:chat-1', commands[index], self.session, description='Harmless test marker')
            self.assertTrue(sent.success, sent.error)
            request = self.requests[-1]
            self.assertEqual(request['type'], 'approval.request')
            self.assertEqual(request['request_id'], queued[index]['request_id'])
            self.assertFalse(markers[index].exists())
            await self.adapter._handle_wire(protocol.approval_response(
                request_id=request['request_id'], conversation_id='chat-1', choice='once'))
            result = await asyncio.wait_for(waiters[index], timeout=2)
            self.assertTrue(result['resolved'])
            self.assertTrue(markers[index].exists())
            if index == 1:
                self.assertFalse(waiters[0].done())
                self.assertFalse(markers[0].exists())
