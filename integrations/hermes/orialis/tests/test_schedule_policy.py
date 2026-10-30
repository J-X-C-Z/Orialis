import asyncio
import json
import os
import unittest
from unittest.mock import patch

from .. import tools

ENV = {'ORIALIS_SERVER_URL': 'https://example.test', 'ORIALIS_DEVICE_TOKEN': 'test'}
EVENT = {'title': '杭州摄影行', 'startAt': '2026-11-03T20:30:00+08:00', 'endAt': '2026-11-09T05:36:00+08:00'}


class SchedulePolicyTests(unittest.TestCase):
    def call(self, name, args):
        return json.loads(asyncio.run(tools.HANDLERS[name][1](args)))

    def test_combined_itineraries_never_write(self):
        descriptions = [
            '【逐日摄影行程】\n11/4（周三）：09:49杭州南抵达→良渚古城。\n11/5（周四）：清晨西湖摄影→中午校园参观。\n11/8（周日）：15:40返程。',
            '08:00–09:00 摄影\n12:00–13:00 校园参观',
            '上午：西湖摄影；下午：校园参观',
            '11月5日：西湖摄影；11月6日：太子湾摄影',
        ]
        for description in descriptions:
            for name in ('create_schedule', 'create_calendar_event', 'update_schedule', 'update_calendar_event', 'create_schedules', 'create_calendar_events'):
                with self.subTest(name=name, description=description), patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request') as request:
                    event = {**EVENT, 'description': description}
                    if name.startswith('update_'):
                        event = {'id': 'e1', 'baseVersion': 1, 'description': description}
                    args = {'items': [{**EVENT, 'title': '单项'}, event]} if name in ('create_schedules', 'create_calendar_events') else event
                    result = self.call(name, args)
                    self.assertFalse(result['ok'])
                    self.assertIn('split_required', result['error'])
                    request.assert_not_called()
                    if 'items' in args:
                        self.assertEqual((result['written'], result['validationIndex']), (0, 1))

    def test_single_overnight_train_and_notes_are_preserved(self):
        event = {**EVENT, 'title': 'D170去程', 'endAt': '2026-11-04T09:49:00+08:00', 'description': '11/3 20:30 广州白云出发，11/4 09:49 杭州南抵达。\n家人接站。'}
        for name in ('create_schedule', 'create_calendar_event'):
            with self.subTest(name=name), patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request', return_value={'ok': True, 'data': {'id': 'train1'}}) as request:
                self.assertTrue(self.call(name, event)['ok'])
                self.assertEqual(request.call_args.kwargs['payload']['description'], event['description'])
        with patch.dict(os.environ, ENV, clear=True), patch.object(tools, '_request', return_value={'ok': True, 'data': {}}) as request:
            self.assertTrue(self.call('update_schedule', {'id': 'e1', 'baseVersion': 1, 'description': None})['ok'])
            request.assert_called_once()
