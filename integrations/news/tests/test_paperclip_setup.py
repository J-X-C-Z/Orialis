import unittest
from unittest.mock import patch

from integrations.news.paperclip_setup import PaperclipApi, apply
from integrations.news.pipeline import PipelineError


class PeriodWorkerTests(unittest.TestCase):
    def test_preview_read_failure_returns_not_ready_for_each_endpoint(self):
        for suffix in ('agents', 'routines', 'projects'):
            with self.subTest(suffix=suffix):
                def request(method, path, payload=None):
                    if path.endswith('/' + suffix):
                        raise PipelineError('read unavailable')
                    if path.endswith('/agents'):
                        return self.agents()
                    if path.endswith('/routines'):
                        return []
                    if path.endswith('/projects'):
                        return [{'id': 'news-project'}]
                    raise AssertionError((method, path))
                with patch.object(PaperclipApi, 'request', side_effect=request) as mocked:
                    result = apply('company', {}, base_url='http://example.invalid', token='', do_apply=False, project_id='news-project')
                self.assertFalse(result['paperclipReadable'])
                self.assertFalse(result['readyToApply'])
                self.assertIn('read unavailable', result['readError'])
                self.assertTrue(all(call.args[0] == 'GET' for call in mocked.call_args_list))

    def agents(self):
        return [
            {'id': 'aihot', 'adapterType': 'process', 'adapterConfig': {'command': 'python3', 'args': ['scripts/news_sources.py', '--refresh', 'aihot']}},
            *[{'id': period, 'adapterType': 'process', 'adapterConfig': {'command': '/usr/bin/python3', 'args': ['-m', 'integrations.news.cli', 'github', period, '--publish']}} for period in ('daily', 'weekly')],
            {'id': 'projects', 'adapterType': 'codex_local'},
        ]

    def run_setup(self, agents, ids=None):
        self.calls = []
        self.created = {}
        def request(method, path, payload=None):
            self.calls.append((method, path, payload))
            if method == 'GET' and path.endswith('/agents'):
                return agents
            if method == 'GET' and path.endswith('/projects'):
                return [{'id': 'news-project'}]
            if method == 'GET' and path.endswith('/routines'):
                return []
            if method == 'POST' and path.endswith('/routines'):
                ident = str(len(self.created) + 1)
                self.created[ident] = payload
                return {'id': ident}
            if method == 'GET' and path.startswith('/api/routines/'):
                return dict(self.created[path.rsplit('/', 1)[-1]], triggers=[])
            if method == 'POST' and path.endswith('/triggers'):
                return {'id': 'trigger'}
            raise AssertionError((method, path))
        with patch.object(PaperclipApi, 'request', side_effect=request):
            return apply('company', ids or {'aihot': 'aihot', 'github-daily': 'daily', 'github-weekly': 'weekly', 'projects': 'projects'}, base_url='http://example.invalid', token='', do_apply=True, project_id='news-project')

    def test_period_specific_workers_are_assigned_and_triggers_stay_disabled(self):
        result = self.run_setup(self.agents())
        routes = {route['key']: route for route in result['routes']}
        self.assertEqual(routes['github-daily']['assigneeAgentId'], 'daily')
        self.assertEqual(routes['github-weekly']['assigneeAgentId'], 'weekly')
        triggers = [payload for method, path, payload in self.calls if method == 'POST' and path.endswith('/triggers')]
        self.assertEqual(len(triggers), 4)
        self.assertTrue(all(t['enabled'] is False for t in triggers))

    def test_lifecycle_wrappers_are_accepted_without_enabling_schedules(self):
        agents = self.agents()
        agents[0]['adapterConfig']['args'] = ['-m', 'integrations.news.worker', '--workflow', 'aihot']
        for agent in agents[1:3]:
            agent['adapterConfig']['args'] = ['-m', 'integrations.news.worker', '--workflow', 'github']
        result = self.run_setup(agents)
        self.assertTrue(result['readyToApply'])
        self.assertTrue(all(not r['triggerEnabled'] for r in result['routes']))

    def test_wrong_lifecycle_workflow_rejected_before_mutation(self):
        agents = self.agents()
        agents[1]['adapterConfig']['args'] = ['-m', 'integrations.news.worker', '--workflow', 'aihot']
        with self.assertRaisesRegex(PipelineError, 'GitHub daily process worker must execute'):
            self.run_setup(agents)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))

    def test_wrong_period_or_missing_publish_rejected_before_mutation(self):
        for argv in (['-m', 'integrations.news.cli', 'github', 'weekly', '--publish'], ['-m', 'integrations.news.cli', 'github', 'daily']):
            with self.subTest(argv=argv):
                agents = self.agents()
                agents[1]['adapterConfig']['args'] = argv
                with self.assertRaisesRegex(PipelineError, 'GitHub daily process worker must execute'):
                    self.run_setup(agents)
                self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))

    def test_aihot_llm_and_projects_process_remain_rejected(self):
        for index, adapter, message in ((0, 'codex_local', 'AIHOT schedule'), (3, 'process', 'Projects routines')):
            with self.subTest(index=index):
                agents = self.agents()
                agents[index]['adapterType'] = adapter
                with self.assertRaisesRegex(PipelineError, message):
                    self.run_setup(agents)
                self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))

    def test_shared_process_cannot_satisfy_both_periods(self):
        ids = {'aihot': 'aihot', 'github': 'daily', 'projects': 'projects'}
        with self.assertRaisesRegex(PipelineError, 'GitHub weekly process worker must execute'):
            self.run_setup(self.agents(), ids)
        self.assertTrue(all(method == 'GET' for method, _, _ in self.calls))


if __name__ == '__main__':
    unittest.main()
