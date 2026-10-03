import asyncio
import json
import os
import unittest
from unittest.mock import patch
from .. import tools

ENV = {'ORIALIS_SERVER_URL': 'https://example.test', 'ORIALIS_DEVICE_TOKEN': 'secret'}
SCHEDULE = {'title': '课程', 'startAt': '2026-10-05T08:00:00+08:00', 'endAt': '2026-10-05T09:00:00+08:00'}

class BatchTests(unittest.TestCase):
    def call(self, name, args):
        return json.loads(asyncio.run(tools.HANDLERS[name][1](args)))

    def test_200_courses_and_201_rejected(self):
        with patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request', return_value={'ok': True, 'data': {'version': 1}}) as request:
            result = self.call('create_schedules', {'items': [dict(SCHEDULE) for _ in range(200)]})
            self.assertEqual(result['succeeded'], 200)
            self.assertEqual(request.call_count, 200)
            ids = [item['submitted']['id'] for item in result['results']]
            self.assertEqual(len(set(ids)), 200)
            request.reset_mock()
            result = self.call('create_schedules', {'items': [dict(SCHEDULE) for _ in range(201)]})
            self.assertFalse(result['ok'])
            request.assert_not_called()

    def test_invalid_batch_never_writes(self):
        bad_batches = ({}, {'items': []}, {'items': 'bad'}, {'items': [{}], 'other': 1})
        for args in bad_batches:
            with self.subTest(args=args), patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request') as request:
                self.assertEqual(self.call('create_tasks', args)['written'], 0)
                request.assert_not_called()
        for bad in ({**SCHEDULE, 'endAt': '2026-10-05T07:00:00+08:00'}, {**SCHEDULE, 'allDay': 1}, {**SCHEDULE, 'id': ''}, {**SCHEDULE, 'title': ' '}, {**SCHEDULE, 'reminderMinutes': -1}):
            with self.subTest(bad=bad), patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request') as request:
                result = self.call('create_schedules', {'items': [SCHEDULE, bad]})
                self.assertEqual(result['validationIndex'], 1)
                self.assertEqual(result['written'], 0)
                request.assert_not_called()

    def test_duplicate_ids_and_missing_credentials(self):
        with patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request') as request:
            result = self.call('create_tasks', {'items': [{'id': 't1', 'title': 'A'}, {'id': 't1', 'title': 'B'}]})
            self.assertFalse(result['ok'])
            request.assert_not_called()
        with patch.dict(os.environ, {}, clear=True), patch.object(tools, '_request') as request:
            self.assertEqual(self.call('create_tasks', {'items': [{'title': 'A'}]})['written'], 0)
            request.assert_not_called()

    def test_partial_failure_continues_without_retry(self):
        replies = [{'ok': True, 'data': {'id': 't1'}}, {'ok': False, 'status': 409, 'error': 'conflict'}, {'ok': False, 'outcomeUnknown': True, 'error': 'timeout'}, {'ok': True, 'data': {'id': 't4'}}]
        with patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request', side_effect=replies) as request:
            result = self.call('create_tasks', {'items': [{'id': f't{i}', 'title': 'Task'} for i in range(1,5)]})
        self.assertEqual(request.call_count, 4)
        self.assertFalse(result['atomic'])
        self.assertFalse(result['ok'])
        self.assertEqual((result['succeeded'], result['failed']), (2, 2))
        self.assertEqual([x['index'] for x in result['results']], [0,1,2,3])
        self.assertEqual(result['results'][1]['status'], 409)
        self.assertTrue(result['results'][2]['outcomeUnknown'])

    def test_each_resource_routes_and_validates(self):
        cases = [
            ('create_schedules', SCHEDULE, '/api/v1/schedules'),
            ('create_calendar_events', SCHEDULE, '/api/v1/calendar-events'),
            ('create_tasks', {'title': 'T', 'projectId': 'p1'}, '/api/v1/tasks'),
            ('create_projects', {'name': 'P'}, '/api/v1/projects'),
            ('create_milestones', {'title': 'M', 'projectId': 'p/1'}, '/api/v1/projects/p%2F1/milestones'),
            ('create_conversations', {'title': 'C'}, '/api/v1/conversations'),
            ('create_messages', {'content': 'Hello', 'conversationId': 'c/1'}, '/api/v1/conversations/c%2F1/messages'),
        ]
        for name, item, path in cases:
            with self.subTest(name=name), patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request', return_value={'ok': True, 'data': {'id': 'created'}}) as request:
                result = self.call(name, {'items': [item]})
                self.assertTrue(result['ok'])
                self.assertEqual(request.call_args.args[3], path)
                body = request.call_args.kwargs['payload']
                if name == 'create_milestones':
                    self.assertNotIn('projectId', body)
                    self.assertNotIn('id', body)
                if name == 'create_messages':
                    self.assertNotIn('conversationId', body)
                schema = tools.HANDLERS[name][0]['parameters']['properties']['items']
                self.assertEqual(schema['maxItems'], 200)
                self.assertTrue(set(schema['items']['required']) <= set(schema['items']['properties']))
        with patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request') as request:
            self.assertFalse(self.call('create_milestones', {'items': [{'title': 'M', 'projectId': 'p1', 'id': 'no'}]})['ok'])
            request.assert_not_called()

    def test_invalid_server_url_is_rejected_before_writes(self):
        for name, item in (('create_schedules', SCHEDULE), ('create_tasks', {'title': 'T'})):
            with patch.dict(os.environ, {**ENV, 'ORIALIS_SERVER_URL': 'invalid'}, clear=True), patch.object(tools, '_request') as request:
                self.assertEqual(self.call(name, {'items': [item]})['written'], 0)
                request.assert_not_called()

    def test_real_http_200_course_payloads(self):
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from threading import Thread
        received = []
        class API(BaseHTTPRequestHandler):
            def do_POST(self):
                self.server.test.assertEqual(self.path, '/api/v1/schedules')
                self.server.test.assertEqual(self.headers['Authorization'], 'Bearer secret')
                payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                received.append(payload)
                self.send_response(201)
                self.end_headers()
                self.wfile.write(json.dumps({**payload, 'version': 1}).encode())
            def log_message(self, *_args):
                pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), API)
        server.test = self
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with patch.dict(os.environ, {**ENV, 'ORIALIS_SERVER_URL': f'http://127.0.0.1:{server.server_port}'}, clear=True):
                result = self.call('create_schedules', {'items': [{**SCHEDULE, 'title': f'课程{i}'} for i in range(200)]})
            self.assertEqual(result['succeeded'], 200)
            self.assertEqual(len(received), 200)
            self.assertEqual([x['title'] for x in received], [f'课程{i}' for i in range(200)])
            self.assertEqual(len({x['id'] for x in received}), 200)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_http_errors_keep_status_and_uncertain_writes(self):
        from urllib.error import HTTPError, URLError
        for error, uncertain in ((HTTPError('https://example.test', 403, 'denied', {}, None), False), (HTTPError('https://example.test', 503, 'down', {}, None), True), (URLError('timeout'), True)):
            with self.subTest(error=error), patch.object(tools, 'urlopen', side_effect=error):
                result = tools._request('https://example.test', 'secret', 'POST', '/api/v1/tasks', payload={'title': 'T'})
                self.assertEqual(result['outcomeUnknown'], uncertain)
                if isinstance(error, HTTPError):
                    self.assertEqual(result['status'], error.code)
