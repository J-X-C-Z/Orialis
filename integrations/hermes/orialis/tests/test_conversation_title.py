import unittest
from types import SimpleNamespace
from unittest.mock import patch

from ..conversation_title import name_conversation


class ConversationTitleTests(unittest.IsolatedAsyncioTestCase):
    async def run_name(self, row=None, generated='电路复习安排', patch_status=200):
        config = SimpleNamespace(server_url='https://example.test', device_token='test')
        with patch('integrations.hermes.orialis.conversation_title._request') as request, patch(
            'integrations.hermes.orialis.conversation_title._call_initial_model',
            return_value={'choices': [{'message': {'content': generated}}]},
        ) as model:
            request.side_effect = [
                {'ok': True, 'data': [row or {'id': 'chat', 'title': '新会话', 'version': 1}]},
                {'ok': patch_status == 200, 'status': patch_status},
            ]
            await name_conversation(config, 'chat', '帮我安排电路复习')
            return request, model

    async def test_real_auxiliary_request_and_cas_patch(self):
        request, model = await self.run_name()
        self.assertEqual(model.call_args.kwargs['task'], 'orialis_initial_response')
        self.assertIn('帮我安排电路复习', model.call_args.kwargs['messages'][1]['content'])
        self.assertEqual(request.call_args.kwargs['payload'], {'title': '电路复习安排', 'baseVersion': 1})

    async def test_custom_or_manually_edited_names_are_untouched(self):
        for title, version in [('自定义标题', 1), ('新会话', 2)]:
            request, model = await self.run_name({'id': 'chat', 'title': title, 'version': version})
            model.assert_not_called()
            self.assertEqual(request.call_count, 1)

    async def test_invalid_model_result_never_replaces_placeholder(self):
        request, _ = await self.run_name(generated='标题\n解释')
        self.assertEqual(request.call_count, 1)

    async def test_conflict_does_not_retry_over_manual_rename(self):
        request, _ = await self.run_name(patch_status=409)
        self.assertEqual(request.call_count, 2)
