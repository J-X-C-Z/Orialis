"""A persisted final marker requires explicit turn-final evidence, not stream closure."""
import unittest
from types import SimpleNamespace
from unittest.mock import Mock
from . import test_native_transport as transport_tests


class FinalIdentityTests(unittest.IsolatedAsyncioTestCase):
    setUp = transport_tests.NativeTransportTests.setUp
    asyncTearDown = transport_tests.NativeTransportTests.asyncTearDown

    async def test_only_notified_conversational_final_has_durable_final_identity(self):
        for metadata in [None, {'notify': True, 'non_conversational': True}]:
            with self.subTest(metadata=metadata):
                result = await self.adapter.send('orialis:chat', '公开进展', metadata=metadata)
                self.assertTrue(result.success)
                self.assertTrue(result.message_id.startswith('msg_'))
        result = await self.adapter.send('orialis:chat', '完整回复', metadata={'notify': True})
        self.assertRegex(result.message_id, r'^final_[a-f0-9]{24}$')
        repeated = await self.adapter.send('orialis:chat', '完整回复', metadata={'notify': True})
        self.assertEqual(result.message_id, repeated.message_id)
        other_anchor = await self.adapter.send('orialis:chat', '完整回复', reply_to='other-user', metadata={'notify': True})
        self.assertNotEqual(result.message_id, other_anchor.message_id)

    async def test_native_commentary_is_a_stable_progress_summary_not_final(self):
        for metadata in [{'_interim_send': True}, {'notify': True, '_interim_send': True}]:
            result = await self.adapter.send('orialis:chat', '已定位索引问题，继续核对边界。', metadata=metadata)
            self.assertRegex(result.message_id, r'^progress_[a-f0-9]{24}$')
            repeated = await self.adapter.send('orialis:chat', '已定位索引问题，继续核对边界。', metadata=metadata)
            self.assertEqual(result.message_id, repeated.message_id)
        mapped = 'msg_existing_stream'
        self.adapter._stream_reply_ids[('orialis:chat', 'user-message', '前置文字')] = mapped
        replay = await self.adapter.send('orialis:chat', '前置文字', metadata={'_interim_send': True})
        self.assertEqual(replay.message_id, mapped)

    async def test_interim_attachment_keeps_regular_message_rendering(self):
        result = await self.adapter.send('orialis:chat', '检查看到的图片',
            metadata={'_interim_send': True, 'attachments': [{'id': 'image'}]})
        self.assertTrue(result.message_id.startswith('msg_'))

    async def test_legacy_interim_heartbeat_is_transient_and_does_not_pollute_public_notes(self):
        content = '⏳ 正在处理——3 分钟 — 第 1/500 轮迭代, terminal'
        updates = SimpleNamespace(public_output=Mock(), close=Mock())
        self.adapter._turn_updates['user-message'] = updates
        try:
            result = await self.adapter.send('orialis:chat', content, metadata={'_interim_send': True})
            self.assertTrue(result.success)
            self.assertIsNone(result.message_id)
            updates.public_output.assert_not_called()
            self.assertFalse([frame for frame in self.frames if frame['type'] == 'message.reply'])
        finally:
            self.adapter._turn_updates.pop('user-message')
        ordinary = await self.adapter.send('orialis:chat', content)
        self.assertTrue(ordinary.message_id.startswith('msg_'))

    async def test_localized_setup_notice_does_not_cancel_initial_or_become_final(self):
        updates = SimpleNamespace(public_output=Mock(), close=Mock())
        self.adapter._turn_updates['user-message'] = updates
        try:
            for content in ['📬 No home channel is set for Orialis.', '📬 Orialis 尚未设置主频道。请先设置。']:
                result = await self.adapter.send('orialis:chat', content, metadata={'notify': True})
                self.assertTrue(result.message_id.startswith('msg_'))
            updates.public_output.assert_not_called()
            updates.close.assert_not_called()
        finally:
            self.adapter._turn_updates.pop('user-message')

    async def test_native_boundary_and_empty_close_are_not_true_final(self):
        for content, explicit in [('等待用户选择', False), ('', True)]:
            with self.subTest(content=content):
                self.assertTrue(await self.adapter.send_stream_frame(
                    '前置说明', chat_id='orialis:chat', turn_id='boundary', finalize=False))
                self.assertTrue(await self.adapter.send_stream_frame(
                    content, chat_id='orialis:chat', turn_id='boundary', finalize=True, is_turn_final=explicit))
                reply = [f for f in self.frames if f['type'] == 'message.reply'][-1]
                self.assertTrue(reply['message_id'].startswith('msg_'))
                complete = [f for f in self.frames if f['type'] == 'agent.complete'][-1]
                self.assertEqual(complete['message_id'], reply['message_id'])

    async def test_explicit_native_final_retry_and_regular_fallback_share_identity(self):
        self.reply_status = 'rejected'
        self.assertFalse(await self.adapter.send_stream_frame(
            '完整结果', chat_id='orialis:chat', turn_id='final', finalize=True, is_turn_final=True))
        first = [f for f in self.frames if f['type'] == 'message.reply'][-1]
        self.assertRegex(first['message_id'], r'^final_[a-f0-9]{24}$')
        self.reply_status = 'received'
        self.assertTrue(await self.adapter.send_stream_frame(
            '完整结果', chat_id='orialis:chat', turn_id='final', finalize=True, is_turn_final=True))
        second = [f for f in self.frames if f['type'] == 'message.reply'][-1]
        complete = [f for f in self.frames if f['type'] == 'agent.complete'][-1]
        self.assertEqual(first['message_id'], second['message_id'])
        self.assertEqual(second['message_id'], complete['message_id'])
        fallback = await self.adapter.send('orialis:chat', '完整结果', metadata={'notify': True})
        self.assertEqual(fallback.message_id, complete['message_id'])

    async def test_empty_native_checkmark_still_declines_and_real_fallback_can_be_final(self):
        self.assertFalse(await self.adapter.send_stream_frame(
            '✅', chat_id='orialis:chat', finalize=True, is_turn_final=True))
        self.assertFalse(self.frames)
        result = await self.adapter.send('orialis:chat', '✅', metadata={'notify': True})
        self.assertRegex(result.message_id, r'^final_[a-f0-9]{24}$')

    async def test_empty_native_abandon_retires_stream_without_reply_or_completion(self):
        self.assertTrue(await self.adapter.send_stream_frame('', chat_id='orialis:chat', turn_id='empty'))
        self.assertIn('empty', self.adapter._active_streams)
        self.frames.clear()
        self.assertTrue(await self.adapter.send_stream_frame(
            '', chat_id='orialis:chat', turn_id='empty', finalize=True, is_turn_final=True))
        self.assertFalse(self.adapter._active_streams)
        self.assertFalse(self.adapter._stream_context)
        self.assertFalse(self.frames)
        self.assertTrue(await self.adapter.send_stream_frame(
            '', chat_id='orialis:chat', turn_id='absent', finalize=True))
        self.assertFalse(self.frames)

    async def test_final_attachment_identity_includes_attachment_payload(self):
        first = await self.adapter.send('orialis:chat', '文件', metadata={'notify': True, 'attachments': [{'id': 'first'}]})
        second = await self.adapter.send('orialis:chat', '文件', metadata={'notify': True, 'attachments': [{'id': 'second'}]})
        self.assertRegex(first.message_id, r'^final_[a-f0-9]{24}$')
        self.assertNotEqual(first.message_id, second.message_id)
