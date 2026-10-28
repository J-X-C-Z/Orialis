"""The host receives generation guidance through its supported system hook."""
import asyncio
from datetime import date, datetime
import json
import math
from pathlib import Path
import re
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from xml.etree import ElementTree

from ..response_ui import PLATFORM_HINT, RESPONSE_UI
from ..tools import handle_capabilities


class ResponseUiTests(unittest.TestCase):
    def test_registered_platform_hint_reaches_actual_hermes_prompt_hook(self):
        from ..adapter import register
        from agent.system_prompt import platform_hint
        from gateway.platform_registry import platform_registry

        ctx = Mock()
        register(ctx)
        entry = SimpleNamespace(**ctx.register_platform.call_args.kwargs)
        self.assertEqual(entry.platform_hint, PLATFORM_HINT)
        with patch.object(platform_registry, 'get', return_value=entry):
            hint = platform_hint(SimpleNamespace(platform='orialis'))
        self.assertIn('proactively', hint)
        self.assertIn('ordinary answers', hint)
        self.assertIn('fallback', hint)
        self.assertIn('do not automatically send', hint)
        for block_type in RESPONSE_UI['block_types']:
            self.assertIn(block_type + ':', hint)

    def test_generation_examples_and_shared_mobile_fixture_match_advertised_format(self):
        examples = re.findall(r'```orialis-ui\n(.*?)\n```', PLATFORM_HINT, re.S)
        self.assertEqual(len(examples), 6)
        fixture = Path(__file__).resolve().parents[4] / 'docs/contracts/response-ui-v1.example.json'
        examples.append(fixture.read_text(encoding='utf-8'))
        extended_fixture = fixture.with_name('response-ui-v1.extended.example.json')
        examples.append(extended_fixture.read_text(encoding='utf-8'))
        board_fixture = fixture.with_name('response-ui-v1.board.example.json')
        examples.append(board_fixture.read_text(encoding='utf-8'))
        for raw in examples:
            doc = json.loads(raw)
            self.assertEqual(doc['version'], RESPONSE_UI['version'])
            self.assertTrue(doc['fallback'].strip())
            self.assertLessEqual(len(raw.encode('utf-8')), RESPONSE_UI['limits']['json_bytes'])
            self.assertTrue(1 <= len(doc['blocks']) <= RESPONSE_UI['limits']['blocks'])
            for block in doc['blocks']:
                self.assertIn(block['type'], RESPONSE_UI['block_types'])
                self.assertTrue(1 <= len(block['items']) <= RESPONSE_UI['limits']['items'])
        svg_items = [item for raw in examples for block in json.loads(raw)['blocks']
                     if block['type'] == 'svg' for item in block['items']]
        self.assertTrue(svg_items)
        for item in svg_items:
            self.assertTrue(item['label'].strip())
            self.assertLessEqual(len(item['source']), RESPONSE_UI['limits']['source'])
            root = ElementTree.fromstring(item['source'])
            self.assertEqual(root.tag, '{http://www.w3.org/2000/svg}svg')
            view_box = list(map(float, root.attrib['viewBox'].split()))
            self.assertEqual(len(view_box), 4)
            self.assertTrue(0 < view_box[2] <= 10000 and 0 < view_box[3] <= 10000)
        self.assertEqual({b['type'] for raw in examples for b in json.loads(raw)['blocks']}, set(RESPONSE_UI['block_types']))
        for raw in examples:
            for block in json.loads(raw)['blocks']:
                for item in block['items']:
                    self.assertTrue(item['label'].strip())
                    if block['type'] == 'plot':
                        self.assertIn(block['kind'], RESPONSE_UI['plot_kinds'])
                        self.assertLessEqual(len(item['points']), RESPONSE_UI['limits']['points'])
                    if block['type'] == 'math':
                        self.assertLessEqual(len(item['source']), RESPONSE_UI['limits']['math_source'])

    def test_board_fixture_covers_additions_with_authored_bounded_data(self):
        fixture = Path(__file__).resolve().parents[4] / 'docs/contracts/response-ui-v1.board.example.json'
        doc = json.loads(fixture.read_text(encoding='utf-8'))
        blocks = doc['blocks']
        self.assertEqual([block['type'] for block in blocks],
                         ['progress', 'heatmap', 'accordion', 'plot', 'plot', 'plot'])
        self.assertEqual({b['kind'] for b in blocks if b['type'] == 'plot'},
                         {'area', 'bar', 'radar'})
        self.assertIn('演示数据', doc['fallback'])
        self.assertEqual(blocks[0]['style'], 'ring')
        self.assertTrue(any('max' not in item for item in blocks[0]['items']))
        for item in blocks[0]['items']:
            maximum = item.get('max', 100)
            self.assertTrue(math.isfinite(maximum) and 0 < maximum <= 1e6)
            self.assertTrue(math.isfinite(item['value']) and 0 <= item['value'] <= maximum)
            self.assertLessEqual(len(item.get('detail', '')), 240)
        for item in blocks[1]['items']:
            self.assertRegex(item['date'], r'^\d{4}-\d{2}-\d{2}$')
            self.assertEqual(date.fromisoformat(item['date']).isoformat(), item['date'])
            self.assertTrue(math.isfinite(item['value']) and 0 <= item['value'] <= 1e6)
        self.assertEqual(len({item['date'] for item in blocks[1]['items']}),
                         len(blocks[1]['items']))
        for item in blocks[2]['items']:
            self.assertTrue(item['content'].strip())
            self.assertLessEqual(len(item['content']), 4000)
        radar = next(block for block in blocks if block.get('kind') == 'radar')
        axes = [p['x'] for p in radar['items'][0]['points']]
        self.assertGreaterEqual(len(axes), 3)
        self.assertLessEqual(len(axes), RESPONSE_UI['limits']['points'])
        for series in radar['items']:
            self.assertEqual([p['x'] for p in series['points']], axes)
            self.assertTrue(all(math.isfinite(p['y']) and 0 <= p['y'] <= 1e6
                                for p in series['points']))

    def test_server_and_plugin_discovery_do_not_drift(self):
        health = Path(__file__).resolve().parents[4] / 'orialis-server/src/health.rs'
        match = re.search(r'response_ui: serde_json::json!\((\{.*?\})\),',
                          health.read_text(encoding='utf-8'), re.S)
        self.assertIsNotNone(match)
        # This discovery literal is JSON with Rust's permitted trailing commas.
        server = json.loads(re.sub(r',(\s*[}\]])', r'\1', match.group(1)))
        self.assertEqual(server, RESPONSE_UI)

    def test_board_guidance_keeps_client_limits_and_confirmation_boundary(self):
        self.assertEqual(len(RESPONSE_UI['block_types']), 26)
        self.assertEqual(RESPONSE_UI['plot_kinds'],
                         ['line', 'scatter', 'pie', 'area', 'bar', 'radar'])
        self.assertEqual(RESPONSE_UI['version'], 1)
        self.assertEqual(RESPONSE_UI['limits']['blocks'], 12)
        self.assertEqual(RESPONSE_UI['limits']['json_bytes'], 32768)
        for instruction in (
            'multiple separate closed fences',
            'Output only\nthe client-supported types',
            'Never fabricate quota, task completion, or live progress',
            'observed or user-provided data',
            'author-supplied data or verified service state',
            'does not create, send, save or execute anything',
            'the user must open and confirm each card',
            'do not automatically send',
        ):
            self.assertIn(instruction, PLATFORM_HINT)

    def test_capabilities_distinguish_plugin_format_from_server_discovery(self):
        with patch.dict('os.environ', {'ORIALIS_SERVER_URL': 'https://example.test'}), \
             patch('integrations.hermes.orialis.tools._fetch_server_capabilities',
                   return_value={'ok': True, 'payload': {'api_version': 'v1', 'response_ui': RESPONSE_UI}}):
            discovery = json.loads(asyncio.run(handle_capabilities({})))
        self.assertEqual(discovery['plugin']['response_ui'], RESPONSE_UI)
        self.assertEqual(discovery['server']['response_ui'], RESPONSE_UI)

    def test_new_block_example_obeys_field_limits_and_agenda_timezone_order(self):
        raw, = re.findall(r'Example of all six new types.*?```orialis-ui\n(.*?)\n```',
                          PLATFORM_HINT, re.S)
        doc = json.loads(raw)
        blocks = {block['type']: block for block in doc['blocks']}
        self.assertEqual(set(blocks),
                         {'callout', 'steps', 'comparison', 'facts', 'code', 'agenda'})
        self.assertTrue(doc['fallback'].strip())
        callout = blocks['callout']['items'][0]
        self.assertIn(callout['tone'], {'info', 'success', 'warning', 'critical'})
        self.assertTrue(callout['content'].strip())
        self.assertLessEqual(len(callout['content']), 4000)
        for item in blocks['steps']['items']:
            self.assertIn(item['status'], {'pending', 'current', 'done'})
            self.assertLessEqual(len(item.get('detail', '')), 1000)
        comparison = blocks['comparison']
        columns = comparison['columns']
        self.assertTrue(2 <= len(columns) <= 4)
        self.assertEqual(len(set(columns)), len(columns))
        self.assertTrue(0 <= comparison['recommendedIndex'] < len(columns))
        for item in comparison['items']:
            self.assertEqual(len(item['values']), len(columns))
            self.assertTrue(all(len(value) <= 1000 for value in item['values']))
        for item in blocks['facts']['items']:
            self.assertTrue(item['value'].strip())
            self.assertLessEqual(len(item['value']), 1000)
            self.assertLessEqual(len(item.get('detail', '')), 240)
        for item in blocks['code']['items']:
            self.assertTrue(item['source'].strip())
            self.assertLessEqual(len(item['source']), 16000)
            self.assertLessEqual(len(item.get('language', '')), 32)
        for item in blocks['agenda']['items']:
            self.assertTrue(item['id'].strip() and item['label'].strip() and item['title'].strip())
            start, end = datetime.fromisoformat(item['startAt']), datetime.fromisoformat(item['endAt'])
            self.assertIsNotNone(start.utcoffset())
            self.assertIsNotNone(end.utcoffset())
            self.assertLess(start, end)
            self.assertLessEqual(len(item.get('notes', '')), 4000)
            self.assertLessEqual(len(item.get('location', '')), 240)
