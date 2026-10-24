"""Contextual, non-thinking initial calls and stable retry content."""
import asyncio
import time
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from ..initial_response import generate_initial_response


class ContextualInitialResponseTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.cache = Path(self.directory.name) / "initial-response.json"
        self.event = SimpleNamespace(text="帮我比较高铁和自驾去杭州", raw_message={})

    async def test_context_and_explicit_no_thinking_reach_the_auxiliary_call(self):
        response = {"choices": [{"message": {"content": "我来比较一下去杭州坐高铁和自驾各自的取舍。", "reasoning": ""}}]}
        with patch("agent.auxiliary_client.call_llm", new=Mock(return_value=response)) as model:
            text = await generate_initial_response(self.event, self.cache)
        self.assertIn("杭州", text)
        self.assertNotIn("private", text)
        kwargs = model.call_args.kwargs
        self.assertEqual(kwargs["task"], "orialis_initial_response")
        self.assertEqual(kwargs["extra_body"], {"chat_template_kwargs": {"thinking": False, "enable_thinking": False}})
        self.assertEqual(json.loads(kwargs["messages"][1]["content"])["message"], self.event.text)
        self.assertNotIn("tools", kwargs)

    async def test_retry_uses_saved_reply_even_when_the_model_would_generate_different_text(self):
        model = Mock(side_effect=[{"choices": [{"message": {"content": "先对比一下高铁和自驾的时间与费用。"}}]}, AssertionError("must not regenerate")])
        with patch("agent.auxiliary_client.call_llm", new=model):
            first = await generate_initial_response(self.event, self.cache)
            second = await generate_initial_response(self.event, self.cache)
        self.assertEqual(first, second)
        self.assertEqual(model.call_count, 1)
        self.assertNotIn(self.event.text, self.cache.read_text(encoding="utf-8"))

    async def test_distinct_messages_receive_their_own_contextual_reply(self):
        model = Mock(side_effect=[
            {"choices": [{"message": {"content": "我先比较出行方式的取舍。"}}]},
            {"choices": [{"message": {"content": "我先检查这段程序的报错位置。"}}]},
        ])
        with patch("agent.auxiliary_client.call_llm", new=model):
            first = await generate_initial_response(self.event, self.cache)
            event = SimpleNamespace(text="这段程序为什么报错？", raw_message={})
            second = await generate_initial_response(event, self.cache.with_name("other.json"))
        self.assertNotEqual(first, second)
        self.assertIn("程序", second)

    async def test_attachment_names_are_evidence_not_a_claim_that_files_were_read(self):
        self.event.raw_message = {"attachments": [{"name": "行程.pdf", "download_url": "private-url"}]}
        model = Mock(return_value={"choices": [{"message": {"content": "收到行程文件，我先看看你的安排。"}}]})
        with patch("agent.auxiliary_client.call_llm", new=model):
            await generate_initial_response(self.event, self.cache)
        request = model.call_args.kwargs
        evidence = json.loads(request["messages"][1]["content"])
        self.assertEqual(evidence["attachment_names"], ["行程.pdf"])
        self.assertNotIn("private-url", json.dumps(request))

    async def test_auxiliary_failure_keeps_a_retry_stable_fallback_and_never_exposes_reasoning(self):
        model = Mock(return_value={"choices": [{"message": {"content": None, "reasoning": "hidden-only"}}]})
        with patch("agent.auxiliary_client.call_llm", new=model):
            text = await generate_initial_response(self.event, self.cache)
            self.assertEqual(await generate_initial_response(self.event, self.cache), text)
        self.assertTrue(text)
        self.assertNotIn("hidden-only", text)
        self.assertEqual(model.call_count, 1)

    async def test_changed_input_cannot_reuse_another_acknowledgement(self):
        with patch("agent.auxiliary_client.call_llm", new=Mock(return_value={"choices": [{"message": {"content": "我先比较出行方案。"}}]})):
            await generate_initial_response(self.event, self.cache)
        self.event.text = "另一条不同的请求"
        with self.assertRaisesRegex(ValueError, "input changed"):
            await generate_initial_response(self.event, self.cache)

    async def test_backend_that_ignores_non_thinking_mode_is_not_reported_as_success(self):
        model = Mock(return_value={"choices": [{"message": {"content": "看起来正常的回答", "reasoning": "hidden thinking"}}]})
        with patch("agent.auxiliary_client.call_llm", new=model):
            text = await generate_initial_response(self.event, self.cache)
        self.assertNotEqual(text, "看起来正常的回答")
        self.assertEqual(json.loads(self.cache.read_text(encoding="utf-8"))["mode"], "fallback")

    async def test_blocked_sdk_does_not_block_gateway_or_timeout(self):
        def blocked(**kwargs):
            time.sleep(.15)
            return {"choices": [{"message": {"content": "迟到的回复"}}]}
        with patch("agent.auxiliary_client.call_llm", side_effect=blocked), patch(
            "integrations.hermes.orialis.initial_response.INITIAL_RESPONSE_TIMEOUT", .02
        ):
            started = time.monotonic()
            text = await generate_initial_response(self.event, self.cache)
            self.assertLess(time.monotonic() - started, .12)
            self.assertNotEqual(text, "迟到的回复")
            self.assertEqual(json.loads(self.cache.read_text())["mode"], "fallback")
            await asyncio.sleep(.18)
            self.assertEqual(json.loads(self.cache.read_text())["content"], text)
