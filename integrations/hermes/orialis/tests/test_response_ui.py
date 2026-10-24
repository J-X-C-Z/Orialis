"""The host receives generation guidance through its supported system hook."""
import asyncio
import json
from pathlib import Path
import re
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from ..adapter import register
from ..response_ui import PLATFORM_HINT, RESPONSE_UI
from ..tools import handle_capabilities


class ResponseUiTests(unittest.TestCase):
    def test_registered_platform_hint_reaches_actual_hermes_prompt_hook(self):
        from agent.system_prompt import platform_hint
        from gateway.platform_registry import platform_registry

        ctx = Mock()
        register(ctx)
        entry = SimpleNamespace(**ctx.register_platform.call_args.kwargs)
        self.assertEqual(entry.platform_hint, PLATFORM_HINT)
        with patch.object(platform_registry, 'get', return_value=entry):
            hint = platform_hint(SimpleNamespace(platform='orialis'))
        self.assertIn('automatically', hint)
        self.assertIn('ordinary answers', hint)
        self.assertIn('fallback', hint)
        self.assertIn('do not automatically send', hint)
        for block_type in RESPONSE_UI['block_types']:
            self.assertIn(block_type + ':', hint)

    def test_generation_examples_and_shared_mobile_fixture_match_advertised_format(self):
        examples = re.findall(r'```orialis-ui\n(.*?)\n```', PLATFORM_HINT, re.S)
        self.assertEqual(len(examples), 2)
        fixture = Path(__file__).resolve().parents[4] / 'docs/contracts/response-ui-v1.example.json'
        examples.append(fixture.read_text(encoding='utf-8'))
        for raw in examples:
            doc = json.loads(raw)
            self.assertEqual(doc['version'], RESPONSE_UI['version'])
            self.assertTrue(doc['fallback'].strip())
            self.assertLessEqual(len(raw.encode('utf-8')), RESPONSE_UI['limits']['json_bytes'])
            self.assertTrue(1 <= len(doc['blocks']) <= RESPONSE_UI['limits']['blocks'])
            for block in doc['blocks']:
                self.assertIn(block['type'], RESPONSE_UI['block_types'])
                self.assertTrue(1 <= len(block['items']) <= RESPONSE_UI['limits']['items'])
        self.assertEqual({b['type'] for b in json.loads(examples[-1])['blocks']}, set(RESPONSE_UI['block_types']))

    def test_capabilities_distinguish_plugin_format_from_server_discovery(self):
        with patch.dict('os.environ', {'ORIALIS_SERVER_URL': 'https://example.test'}), \
             patch('integrations.hermes.orialis.tools._fetch_server_capabilities',
                   return_value={'ok': True, 'payload': {'api_version': 'v1', 'response_ui': RESPONSE_UI}}):
            discovery = json.loads(asyncio.run(handle_capabilities({})))
        self.assertEqual(discovery['plugin']['response_ui'], RESPONSE_UI)
        self.assertEqual(discovery['server']['response_ui'], RESPONSE_UI)
