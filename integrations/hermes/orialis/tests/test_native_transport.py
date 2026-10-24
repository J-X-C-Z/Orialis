"""Installed Hermes media and stream consumers against the actual Orialis wire contract."""
import asyncio
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch
import websockets

from gateway.config import Platform
from gateway.stream_consumer import GatewayStreamConsumer, StreamConsumerConfig
from gateway.platforms.event import ProcessingOutcome
from gateway.stream_events import ToolCallChunk
from gateway.status import flush_runtime_status_async
from .. import adapter as adapter_module, protocol
from ..adapter import OrialisAdapter


class NativeTransportTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        initial_response = patch.object(adapter_module, 'generate_initial_response',
            new=AsyncMock(return_value='收到，我先处理一下。'))
        initial_response.start()
        self.addCleanup(initial_response.stop)
        async def contextual_progress(event, facts, directory):
            activity = facts.get('activity')
            if facts['phase'] == 'tool':
                return f"针对{event.text[:24]}，当前正在{activity or '执行任务步骤'}，调用尚未返回。"
            if facts['phase'] == 'returned':
                return f"{event.text[:24]}的工具调用已返回，正在整理可确认的信息。"
            return f"{event.text[:24]}仍在处理中，还没有新增可确认结果。"
        progress_response = patch.object(adapter_module, 'generate_progress_response',
            new=AsyncMock(side_effect=contextual_progress))
        progress_response.start()
        self.addCleanup(progress_response.stop)
        self.home = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {'HERMES_HOME': self.home.name})
        self.env.start()
        Platform._add_pseudo_member('orialis')
        self.adapter = OrialisAdapter(SimpleNamespace(extra={'ack_timeout_seconds': .05}))
        self.adapter._ws = object()
        self.adapter._running = True
        self.adapter._negotiated = True
        self.adapter._server_capabilities = {'streaming', 'approval', 'clarify', 'reply_followups'}
        self.adapter._reply_anchors['orialis:chat'] = 'user-message'
        self.frames = []
        self.event_status = 'received'
        self.reply_status = 'received'

        async def transport(frame):
            self.frames.append(frame)
            if frame.get('event_id'):
                ack = {'version': 1, 'type': 'agent.ack', 'event_id': frame['event_id'],
                       'seq': frame['seq'], 'status': self.event_status}
                if self.event_status == 'gap':
                    ack['expected_seq'] = frame['seq'] + 1
                await self.adapter._handle_wire(ack)
            elif frame['type'] == 'message.reply':
                await self.adapter._handle_wire(protocol.ack(frame['message_id'], status=self.reply_status))
            elif frame['type'] == 'command.reply':
                await self.adapter._handle_wire(protocol.ack(frame['request_id'], status=self.reply_status))
        self.adapter._send_wire = transport

    async def asyncTearDown(self):
        pending_updates = list(self.adapter._turn_updates.values())
        for updates in pending_updates:
            updates.close()
        if pending_updates:
            await asyncio.gather(*(task for updates in pending_updates
                                   for task in (updates.initial_task, updates.task)), return_exceptions=True)
        try:
            # Real connect/disconnect queues native status writes into this temporary home.
            self.assertTrue(await flush_runtime_status_async(), 'Native status writer did not finish before cleanup')
        finally:
            self.env.stop()
            self.home.cleanup()

    async def test_feature_receipt_uses_event_identity_and_sequence_not_request_id(self):
        for status in ['received', 'duplicate', 'gap', 'unknown']:
            self.event_status = status
            frame = protocol.clarify_event(event_type='clarify.request', request_id='question',
                question='Which?', conversation_id='chat', seq=self.adapter._next_event_seq())
            result = await self.adapter._send_feature_request(frame, 'question')
            self.assertEqual(result.success, status in {'received', 'duplicate'})
            self.assertFalse(self.adapter._event_receipts)
            self.assertFalse(self.adapter._ack_waiters)

        captured = asyncio.Event()
        async def hold(frame):
            captured.set()
        self.adapter._send_wire = hold
        frame = protocol.approval_event(event_type='approval.request', request_id='approval',
            conversation_id='chat', action='Harmless test', seq=self.adapter._next_event_seq())
        pending = asyncio.create_task(self.adapter._send_feature_request(frame, 'approval'))
        await captured.wait()
        for event_id, seq in [('unrelated', frame['seq']), (frame['event_id'], frame['seq'] + 1)]:
            await self.adapter._handle_wire({'version': 1, 'type':'agent.ack', 'event_id':event_id,
                'seq':seq, 'status':'received'})
            self.assertFalse(pending.done())
        await self.adapter._handle_wire({'version':1, 'type':'agent.ack', 'event_id':frame['event_id'],
            'seq':frame['seq'], 'status':'received'})
        self.assertTrue((await pending).success)

    async def test_installed_media_delivery_omits_reply_to_and_uses_chat_anchor(self):
        marker = Path(self.home.name, 'marker.txt')
        marker.write_text('real existing marker')
        uploaded = []
        def upload(path, *args):
            uploaded.append(Path(path).read_bytes())
            return {'id':'attachment-id', 'name':'marker.txt', 'mime_type':'text/plain',
                'size':marker.stat().st_size, 'download_url':'https://orialis.test/api/v1/attachments/attachment-id/download'}
        delivered = []
        event = SimpleNamespace(source=SimpleNamespace(chat_id='orialis:chat'))
        with patch.object(adapter_module, '_upload_attachment', upload):
            await self.adapter._deliver_media_attachments(event, [(str(marker), False)], [],
                force_document_attachments=False, human_delay=0, metadata={}, record_delivery=delivered.append)
        self.assertEqual(uploaded, [marker.read_bytes()])
        self.assertTrue(delivered[0].success)
        reply = self.frames[-1]
        self.assertEqual(reply['reply_to'], 'user-message')
        self.assertEqual(reply['attachments'][0]['id'], 'attachment-id')
        self.adapter._reply_anchors.clear()
        with patch.object(adapter_module, '_upload_attachment') as upload_mock:
            self.assertFalse((await self.adapter.send_document('orialis:chat', str(marker))).success)
            upload_mock.assert_not_called()

    async def test_native_consumer_snapshots_final_tail_and_persistent_reply(self):
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat',
            config=StreamConsumerConfig(edit_interval=0, buffer_threshold=1, cursor=''),
            initial_reply_to_id='user-message')
        await consumer._send_frame('Hello', finalize=False)
        await consumer._send_frame('Hello world', finalize=False)
        await consumer._send_frame('Hello world', finalize=False)
        await consumer._send_frame('Hello world!', finalize=True)
        self.assertEqual([f['delta'] for f in self.frames if f['type']=='agent.delta'], ['Hello', ' world', '!'])
        self.assertEqual([f['content'] for f in self.frames if f['type']=='message.reply'], ['Hello world!'])
        complete = next(f for f in self.frames if f['type']=='agent.complete')
        self.assertEqual(complete['content'], 'Hello world!')
        self.assertTrue(complete['run_id'].startswith(consumer._turn_id + ':'))
        self.assertEqual(complete['run_id'], next(f for f in self.frames if f['type']=='agent.start')['run_id'])
        self.assertEqual(complete['message_id'], next(f for f in self.frames if f['type']=='message.reply')['message_id'])
        self.assertFalse(self.adapter._active_streams)

    async def test_native_consumer_real_run_adopts_authoritative_rewrite_and_tail(self):
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat',
            config=StreamConsumerConfig(edit_interval=0, buffer_threshold=1, cursor=''),
            initial_reply_to_id='user-message')
        consumer.on_delta('draft wrong')
        consumer.finish('Correct final with trailing tail')
        await asyncio.wait_for(consumer.run(), timeout=2)
        replies = [f for f in self.frames if f['type']=='message.reply']
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]['content'], 'Correct final with trailing tail')
        self.assertTrue(consumer.delivered_final_matches('Correct final with trailing tail'))

    async def test_response_ui_stream_complete_and_durable_reply_keep_same_content(self):
        fixture = Path(__file__).resolve().parents[4] / 'docs/contracts/response-ui-v1.example.json'
        content = '今天的学习安排。\n\n```orialis-ui\n' + fixture.read_text(encoding='utf-8') + '\n```'
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat',
            config=StreamConsumerConfig(edit_interval=0, buffer_threshold=1, cursor=''),
            initial_reply_to_id='user-message')
        split = content.index('"blocks"')
        await consumer._send_frame(content[:split], finalize=False)
        await consumer._send_frame(content, finalize=True)
        self.assertEqual(''.join(f['delta'] for f in self.frames if f['type'] == 'agent.delta'), content)
        self.assertEqual([f['content'] for f in self.frames if f['type'] == 'message.reply'], [content])
        self.assertEqual(next(f for f in self.frames if f['type'] == 'agent.complete')['content'], content)

        malformed = '仍然保留文字。\n```orialis-ui\n{broken}\n```'
        self.assertTrue((await self.adapter.send('orialis:chat', malformed)).success)
        self.assertEqual(self.frames[-1]['content'], malformed)

    async def test_large_response_ui_is_not_split_into_invalid_json_on_legacy_host_path(self):
        fixture = Path(__file__).resolve().parents[4] / 'docs/contracts/response-ui-v1.example.json'
        doc = json.loads(fixture.read_text(encoding='utf-8'))
        for item in doc['blocks'][2]['items']:
            item['content'] += ' Details.' * 350
        content = '学习安排。\n```orialis-ui\n' + json.dumps(doc, ensure_ascii=False) + '\n```'
        self.assertGreater(len(content), 4096)
        self.assertLess(len(content.encode('utf-8')), 32768)
        self.adapter._server_capabilities.remove('reply_followups')
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat',
            config=StreamConsumerConfig(edit_interval=0, buffer_threshold=1, cursor=''),
            initial_reply_to_id='user-message')
        consumer.on_delta(content)
        consumer.finish(content)
        await asyncio.wait_for(consumer.run(), timeout=2)
        self.assertEqual([f['content'] for f in self.frames if f['type'] == 'message.reply'], [content])

    async def test_rewrite_pauses_append_until_complete_replaces_and_boundary_reopens(self):
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat', initial_reply_to_id='user-message')
        await consumer._send_frame('wrong prefix', finalize=False)
        await consumer._send_frame('correct', finalize=False)
        await consumer._send_frame('correct answer', finalize=True)
        self.assertEqual([f['delta'] for f in self.frames if f['type']=='agent.delta'], ['wrong prefix'])
        self.assertEqual([f['content'] for f in self.frames if f['type']=='agent.complete'], ['correct answer'])
        await consumer._send_frame('', finalize=False)
        await consumer._send_frame('after boundary', finalize=True)
        self.assertEqual([f['content'] for f in self.frames if f['type']=='message.reply'], ['correct answer','after boundary'])
        self.assertEqual(len({f['event_id'] for f in self.frames if f.get('event_id')}),
                         len([f for f in self.frames if f.get('event_id')]))
        self.assertEqual(len({f['run_id'] for f in self.frames if f['type']=='agent.start'}), 2)

    async def test_old_event_only_server_does_not_enable_native_delivery(self):
        self.adapter._server_capabilities.remove('reply_followups')
        self.assertFalse(self.adapter.supports_native_streaming('orialis:chat'))
        self.assertFalse(await self.adapter.send_stream_frame('text', chat_id='orialis:chat'))
        self.assertFalse(self.frames)

    async def test_background_turn_keeps_anchor_after_dispatch_and_releases_after_delivery(self):
        accepted = []
        async def handler(event):
            event._gateway_accepted = True
            accepted.append(event)
        self.adapter.handle_message = handler
        self.adapter._reply_anchors.clear()
        await self.adapter._dispatch_message({'version':1, 'type':'message.send',
            'message_id':'background-user', 'conversation_id':'chat', 'content':'send file'})
        event = accepted[0]
        self.assertEqual(self.adapter._reply_anchors['orialis:chat'], 'background-user')
        await self.adapter.on_processing_start(event)
        self.assertTrue((await self.adapter.send('orialis:chat', 'background answer')).success)
        self.assertEqual(self.frames[-1]['reply_to'], 'background-user')
        await self.adapter.on_processing_complete(event, SimpleNamespace(value='success'))
        self.assertNotIn('orialis:chat', self.adapter._reply_anchors)

    async def test_real_socket_reader_receives_ack_while_native_command_awaits_send(self):
        complete = asyncio.get_running_loop().create_future()
        command = protocol.command_request(request_id='slash-request', conversation_id='chat', command='/status')
        async def server(socket):
            await socket.recv()
            await socket.send(json.dumps({'version':1,'type':'hello_ack'}))
            await socket.send(json.dumps(command))
            while True:
                frame = json.loads(await socket.recv())
                if frame['type'] == 'command.reply':
                    await socket.send(json.dumps(protocol.ack('slash-request')))
                    return
                if frame['type'] == 'message.reply':
                    await socket.send(json.dumps(protocol.ack(frame['message_id'])))
                    return
        async with websockets.serve(server, '127.0.0.1', 0) as endpoint:
            port = endpoint.sockets[0].getsockname()[1]
            adapter = OrialisAdapter(SimpleNamespace(extra={'server_url':f'ws://127.0.0.1:{port}',
                'device_id':'JXCZ_TEST_Hermes', 'ack_timeout_seconds':.5}))
            async def native_command(event):
                # This is the installed native slash lifecycle: await send before handler returns.
                complete.set_result(await adapter.send(event.source.chat_id, 'status reply'))
            adapter.handle_message = native_command
            try:
                self.assertTrue(await adapter.connect())
                self.assertTrue((await asyncio.wait_for(complete, timeout=2)).success)
            finally:
                await adapter.disconnect()
            self.assertFalse(adapter._dispatch_tasks)

    async def test_real_socket_reconnect_keeps_epoch_and_fresh_adapter_starts_new_epoch(self):
        observed = []
        async def server(socket):
            await socket.recv()
            await socket.send(json.dumps({'version':1, 'type':'hello_ack'}))
            async for raw in socket:
                frame = json.loads(raw)
                if frame.get('event_id'):
                    observed.append(frame)
                    await socket.send(json.dumps({'version':1, 'type':'agent.ack',
                        'event_id':frame['event_id'], 'seq':frame['seq'], 'status':'received'}))
        async with websockets.serve(server, '127.0.0.1', 0) as endpoint:
            port = endpoint.sockets[0].getsockname()[1]
            config = SimpleNamespace(extra={'server_url':f'ws://127.0.0.1:{port}',
                'device_id':'JXCZ_TEST_Hermes', 'ack_timeout_seconds':.5})
            original = OrialisAdapter(config)
            fresh = OrialisAdapter(config)
            async def send_event(adapter):
                frame = protocol.agent_typing(conversation_id='chat', typing=True,
                    session_id=adapter._session_id, seq=adapter._next_event_seq())
                self.assertTrue((await adapter._send_feature_request(frame, frame['event_id'])).success)
            try:
                self.assertTrue(await original.connect())
                await send_event(original)
                await original.disconnect()
                self.assertTrue(await original.connect(is_reconnect=True))
                await send_event(original)
                await original.disconnect()
                self.assertTrue(await fresh.connect())
                await send_event(fresh)
            finally:
                await original.disconnect()
                await fresh.disconnect()
        self.assertEqual([f['seq'] for f in observed], [1, 2, 1])
        self.assertEqual(observed[0]['session_id'], observed[1]['session_id'])
        self.assertNotEqual(observed[0]['session_id'], observed[2]['session_id'])
        self.assertEqual(len({f['event_id'] for f in observed}), 3)

    async def test_failed_final_receipt_never_claims_delivery_and_retry_reuses_reply_id(self):
        self.reply_status = 'rejected'
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat', initial_reply_to_id='user-message')
        self.assertFalse(await consumer._send_frame('final', finalize=True))
        self.reply_status = 'received'
        self.assertTrue(await consumer._send_frame('final', finalize=True))
        replies = [f for f in self.frames if f['type']=='message.reply']
        self.assertEqual(len(replies), 2)
        self.assertEqual(replies[0]['message_id'], replies[1]['message_id'])
        self.assertFalse(self.adapter._active_streams)

    async def test_native_empty_finalize_preserves_prior_snapshot(self):
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat', initial_reply_to_id='user-message')
        self.assertTrue(await consumer._send_frame('keep boundary text', finalize=False))
        self.assertTrue(await consumer._send_frame('', finalize=True))
        self.assertEqual([f['content'] for f in self.frames if f['type']=='message.reply'], ['keep boundary text'])
        self.assertEqual([f['content'] for f in self.frames if f['type']=='agent.complete'], ['keep boundary text'])

    async def test_parallel_command_does_not_steal_active_background_reply_anchor(self):
        entered, release = asyncio.Event(), asyncio.Event()
        async def native_command(event):
            entered.set()
            await release.wait()
            self.assertTrue((await self.adapter.send(event.source.chat_id, 'command response')).success)
        self.adapter.handle_message = native_command
        self.adapter._server_capabilities.add('slash_commands')
        task = asyncio.create_task(self.adapter._dispatch_command(protocol.command_request(
            request_id='slash', conversation_id='chat', command='/status')))
        await entered.wait()
        self.assertEqual(self.adapter._reply_anchors['orialis:chat'], 'user-message')
        self.assertTrue((await self.adapter.send('orialis:chat', 'active model response')).success)
        reply = self.frames[-1]
        self.assertEqual(reply['type'], 'message.reply')
        self.assertEqual(reply['reply_to'], 'user-message')
        release.set()
        await task
        self.assertEqual(self.frames[-1]['type'], 'command.reply')
        self.assertEqual(self.frames[-1]['request_id'], 'slash')
        self.assertEqual(self.adapter._reply_anchors['orialis:chat'], 'user-message')

    async def test_native_cancel_commits_stop_reply_and_closes_parent_segment_and_tool(self):
        self.adapter._server_capabilities.update({'agent_state', 'tool_state'})
        self.adapter._loop = asyncio.get_running_loop()
        event = SimpleNamespace(message_id='user-message', source=SimpleNamespace(chat_id='orialis:chat'))
        await self.adapter.on_processing_start(event)
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat', initial_reply_to_id='user-message')
        await consumer._send_frame('partial output', finalize=False)
        segment_run = self.adapter._active_streams[consumer._turn_id]['run_id']
        self.adapter.format_tool_event(ToolCallChunk(tool_name='terminal', preview='pwd', index=7))
        # Installed native cancellation abandons draft-only transports and leaves this event stream open.
        await consumer._on_cancelled()
        self.assertTrue(self.adapter._active_streams)
        await self.adapter.on_processing_complete(event, ProcessingOutcome.CANCELLED)
        replies = [f for f in self.frames if f['type']=='message.reply']
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]['reply_to'], 'user-message')
        self.assertEqual(replies[0]['content'], 'partial output\n\n已停止本次任务。')
        completes = [f for f in self.frames if f['type']=='agent.complete']
        self.assertEqual({f['run_id'] for f in completes}, {'user-message', segment_run})
        self.assertTrue(all(f['message_id']==replies[0]['message_id'] for f in completes))
        self.assertFalse(any(f['type']=='agent.status' for f in self.frames))
        ended = next(f for f in self.frames if f['type']=='tool.completed')
        self.assertIn('本轮已取消', ended['output'])
        self.assertIn('未收到单项结果', ended['output'])
        self.assertFalse(self.adapter._active_streams)
        self.assertFalse(self.adapter._active_tools)

    async def test_native_cancel_without_stream_still_commits_original_anchor(self):
        self.adapter._server_capabilities.add('agent_state')
        event = SimpleNamespace(message_id='user-message', source=SimpleNamespace(chat_id='orialis:chat'))
        await self.adapter.on_processing_complete(event, ProcessingOutcome.CANCELLED)
        reply = next(f for f in self.frames if f['type']=='message.reply')
        self.assertEqual(reply['reply_to'], 'user-message')
        self.assertEqual(reply['content'], '已停止本次任务。')
        self.assertEqual(next(f for f in self.frames if f['type']=='agent.complete')['message_id'], reply['message_id'])

    async def test_installed_native_stop_bypass_commits_original_for_http_and_command_inputs(self):
        self.adapter._server_capabilities.update({'agent_state', 'slash_commands'})
        for wire_command in (False, True):
            self.frames.clear()
            original_id = 'original-command' if wire_command else 'original-http'
            original = SimpleNamespace(message_id=original_id, source=SimpleNamespace(chat_id='orialis:chat'))
            await self.adapter.on_processing_start(original)
            session = 'native-stop-test'
            running = asyncio.create_task(asyncio.Event().wait())
            self.adapter._session_tasks[session] = running
            self.adapter._active_sessions[session] = asyncio.Event()
            async def native_reply(event):
                return 'Native stop confirmed'
            self.adapter._message_handler = native_reply
            async def native_dispatch(event):
                # Installed Base stops the real active task after sending its inline command response.
                await self.adapter._dispatch_active_session_command(event, session, 'stop')
            self.adapter.handle_message = native_dispatch
            stop_id = 'stop-command' if wire_command else 'stop-http'
            if wire_command:
                await self.adapter._dispatch_command(protocol.command_request(request_id=stop_id,
                    conversation_id='chat', command='/stop'))
            else:
                await self.adapter._dispatch_message({'version':1,'type':'message.send',
                    'message_id':stop_id,'conversation_id':'chat','content':'/stop'})
            self.assertTrue(running.cancelled())
            original_replies = [f for f in self.frames if f['type']=='message.reply' and f['reply_to']==original_id]
            self.assertEqual(len(original_replies), 1)
            self.assertEqual(original_replies[0]['content'], '已停止本次任务。')
            self.assertNotIn(original_id, self.adapter._active_turn_events)

    async def test_native_stop_without_committed_receipt_does_not_finish_original(self):
        original = SimpleNamespace(message_id='original', source=SimpleNamespace(chat_id='orialis:chat'))
        await self.adapter.on_processing_start(original)
        async def rejected_stop(event):
            self.reply_status = 'rejected'
            self.assertFalse((await self.adapter.send(event.source.chat_id, 'Native stop reply', reply_to=event.message_id)).success)
        self.adapter.handle_message = rejected_stop
        await self.adapter._dispatch_message({'version':1,'type':'message.send',
            'message_id':'stop-failed','conversation_id':'chat','content':'/stop'})
        self.assertIn('original', self.adapter._active_turn_events)
        self.assertFalse(any(f['type']=='message.reply' and f['reply_to']=='original' for f in self.frames))

    async def test_native_stop_without_active_turn_does_not_invent_original_reply(self):
        async def native_stop(event):
            self.assertTrue((await self.adapter.send(event.source.chat_id, 'No active task', reply_to=event.message_id)).success)
        self.adapter.handle_message = native_stop
        await self.adapter._dispatch_message({'version':1,'type':'message.send',
            'message_id':'stop-idle','conversation_id':'chat','content':'/stop'})
        self.assertEqual([f['reply_to'] for f in self.frames if f['type']=='message.reply'], ['stop-idle'])

    async def test_real_base_background_stale_success_before_stop_ack_still_finishes_original(self):
        started, release, finished = asyncio.Event(), asyncio.Event(), asyncio.Event()
        finish_hook = self.adapter.on_processing_complete
        async def observed_finish(event, outcome):
            await finish_hook(event, outcome)
            if event.message_id == 'base-original':
                finished.set()
        self.adapter.on_processing_complete = observed_finish
        async def handler(event):
            if event.text == '/stop':
                release.set()
                await finished.wait()  # Native stale result can finish before the command reply ACK.
                return 'Native stop confirmed'
            started.set()
            await release.wait()
            return None
        self.adapter._message_handler = handler
        await self.adapter._dispatch_message({'version':1,'type':'message.send',
            'message_id':'base-original','conversation_id':'chat','content':'background task'})
        await asyncio.wait_for(started.wait(), timeout=2)
        await asyncio.wait_for(self.adapter._dispatch_message({'version':1,'type':'message.send',
            'message_id':'base-stop','conversation_id':'chat','content':'/stop'}), timeout=2)
        self.assertTrue(finished.is_set())
        replies = [f for f in self.frames if f['type']=='message.reply']
        self.assertEqual([(f['reply_to'], f['content']) for f in replies],
            [('base-original','收到，我先处理一下。'),
             ('base-stop','Native stop confirmed'), ('base-original','已停止本次任务。')])
        self.assertFalse(self.adapter._stop_receipts)

    async def test_native_shared_stream_without_processing_hook_finishes_from_late_reply_ack(self):
        async def shared_admission(event):
            event._gateway_accepted = True
        self.adapter.handle_message = shared_admission
        await self.adapter._dispatch_message({'version':1,'type':'message.send',
            'message_id':'shared-original','conversation_id':'chat','content':'shared task'})
        consumer = GatewayStreamConsumer(self.adapter, 'orialis:chat', initial_reply_to_id='shared-original')
        await consumer._send_frame('partial shared output', finalize=False)
        self.assertFalse(self.adapter._active_turn_events)
        late_task = None
        async def asynchronous_native_stop(event):
            nonlocal late_task
            async def late_reply():
                await asyncio.sleep(0)
                await self.adapter.send(event.source.chat_id, 'Native stop confirmed', reply_to=event.message_id)
            late_task = asyncio.create_task(late_reply())
        self.adapter.handle_message = asynchronous_native_stop
        await self.adapter._dispatch_message({'version':1,'type':'message.send',
            'message_id':'shared-stop','conversation_id':'chat','content':'/stop'})
        self.assertIn('shared-stop', self.adapter._stop_receipts)
        await late_task
        reply = next(f for f in self.frames if f['type']=='message.reply' and f['reply_to']=='shared-original')
        self.assertEqual(reply['content'], 'partial shared output\n\n已停止本次任务。')
        self.assertFalse(self.adapter._stop_receipts)

    async def test_old_hermes_without_admission_modules_still_dispatches_stable_native_input(self):
        real_import = adapter_module.importlib.import_module
        def old_import(name):
            if name == 'gateway.session_authorities':
                raise ModuleNotFoundError("No admission ABI", name=name)
            return real_import(name)
        self.adapter.gateway_runner = SimpleNamespace(session_store=object(),
            _profile_name_for_source=lambda *args, **kwargs:None)
        accepted=[]
        async def native_handler(event):
            event._gateway_accepted=True
            accepted.append(event)
        self.adapter.handle_message=native_handler
        with patch.object(adapter_module.importlib,'import_module',old_import):
            await self.adapter._dispatch_message({'version':1,'type':'message.send','message_id':'old-host',
                'conversation_id':'chat','content':'ordinary native input'})
        self.assertEqual(len(accepted),1)
        self.assertEqual(accepted[0].timestamp.timestamp(),0)
        self.assertEqual(accepted[0].text,'ordinary native input')

    async def test_receipt_feature_probe_does_not_hide_nested_dependency_errors(self):
        def broken_import(name):
            raise ModuleNotFoundError('Real nested dependency is broken', name='missing_dependency')
        with patch.object(adapter_module.importlib,'import_module',broken_import):
            with self.assertRaisesRegex(ModuleNotFoundError,'Real nested dependency'):
                adapter_module._native_receipts_available()
        with patch.object(adapter_module.importlib,'import_module',return_value=SimpleNamespace()):
            self.assertFalse(adapter_module._native_receipts_available())
