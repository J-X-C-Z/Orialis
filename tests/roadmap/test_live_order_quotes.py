"""Ordering and quote contracts. Run only against an isolated test server."""
import unittest
from .support import LiveServerMixin, json_request, session_headers, unique_id


class LiveOrderingQuoteTests(LiveServerMixin, unittest.TestCase):
    def setUp(self):
        token, _ = self.shared_session()
        self.headers = session_headers(token)

    def call(self, method, path, data=None, expected=200):
        result = json_request(method, path, data, headers=self.headers)
        self.assertEqual(result.status, expected, result.body)
        return result.json()

    def test_task_order_reset_versions_and_snapshot(self):
        task = self.call('POST', '/api/v1/tasks', {'title': 'ordered', 'manualPosition': 7}, 201)
        self.assertEqual(task['manualPosition'], 7)
        reset = self.call('PATCH', '/api/v1/tasks/' + task['id'], {'manualPosition': None, 'baseVersion': task['version']})
        self.assertIsNone(reset['manualPosition'])
        self.assertGreater(reset['version'], task['version'])
        self.call('PATCH', '/api/v1/tasks/' + task['id'], {'manualPosition': 9, 'baseVersion': task['version']}, 409)
        snapshot = self.call('GET', '/api/v1/sync/snapshot')
        self.assertIsNone(next(t for t in snapshot['tasks'] if t['id'] == task['id'])['manualPosition'])

    def test_project_preserves_client_id_and_synced_order(self):
        import uuid
        identifier = str(uuid.uuid4())
        project = self.call('POST', '/api/v1/projects', {'id': identifier, 'name': 'local first', 'manualPosition': 2}, 201)
        self.assertEqual(project['id'], identifier)
        self.assertEqual(project['manualPosition'], 2)
        changed = self.call('PATCH', '/api/v1/projects/' + identifier, {'manualPosition': None, 'baseVersion': project['version']})
        self.assertIsNone(changed['manualPosition'])
        snapshot = self.call('GET', '/api/v1/sync/snapshot')
        self.assertEqual(next(p for p in snapshot['projects'] if p['id'] == identifier)['version'], changed['version'])

    def test_conversation_only_pinned_manual_order(self):
        convo = self.call('POST', '/api/v1/conversations', {'title': 'Pinned', 'pinned': True, 'manualPosition': 3}, 201)
        self.assertTrue(convo['pinned'])
        self.assertEqual(convo['manualPosition'], 3)
        self.call('PATCH', '/api/v1/conversations/' + convo['id'], {'title': 'Pinned', 'pinned': False, 'baseVersion': convo['version']}, 400)
        reset = self.call('PATCH', '/api/v1/conversations/' + convo['id'], {'title': 'Pinned', 'pinned': False, 'manualPosition': None, 'baseVersion': convo['version']})
        self.assertFalse(reset['pinned'])
        self.assertIsNone(reset['manualPosition'])

    def test_quote_canonical_snapshot_and_conversation_isolation(self):
        a = self.call('POST', '/api/v1/conversations', {'title': unique_id('quote')}, 201)
        b = self.call('POST', '/api/v1/conversations', {'title': unique_id('other')}, 201)
        path = '/api/v1/conversations/' + a['id'] + '/messages'
        original = self.call('POST', path, {'content': 'original trusted snapshot'}, 201)
        reply = self.call('POST', path, {'content': 'explain this', 'replyToMessageId': original['id'], 'replyQuote': 'forged', 'replyRole': 'assistant'}, 201)
        self.assertEqual(reply['content'], 'explain this')
        self.assertEqual(reply['replyQuote'], original['content'])
        self.assertEqual(reply['replyRole'], 'user')
        remote = self.call('GET', path)
        self.assertEqual(next(m for m in remote if m['id'] == reply['id'])['replyToMessageId'], original['id'])
        self.call('POST', '/api/v1/conversations/' + b['id'] + '/messages', {'content': 'cross conversation', 'replyToMessageId': original['id']}, 400)
        self.call('POST', path, {'content': 'missing relation', 'replyQuote': 'fake'}, 400)
