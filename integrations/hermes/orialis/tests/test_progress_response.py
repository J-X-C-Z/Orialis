"""Context-aware summaries stay public, optional, cached and off the main loop."""
import asyncio
import json
import stat
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from .. import progress_response
from ..progress_response import generate_progress_response


def response(content, **message_fields):
    return {
        "model": "deepseek-flash",
        "choices": [{"message": {"content": content, **message_fields}}],
        "usage": {"completion_tokens_details": {"reasoning_tokens": 0}},
    }


class ProgressResponseTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.addCleanup(self.home.cleanup)
        self.directory = Path(self.home.name)
        self.event = SimpleNamespace(text="比较周末去杭州坐高铁和自驾", raw_message={})
        self.facts = {
            "phase": "tool", "activity": "查找资料",
            "stage_history": [{"phase": "tool", "activity": "查找资料"}],
            "public_notes": ["已确认有两班合适的高铁，还需核对自驾路况。"],
            "previous_updates": ["我先比较交通方式的时间和费用。"],
        }
        warning = patch.object(progress_response.logger, "warning")
        warning.start()
        self.addCleanup(warning.stop)

    async def test_different_requests_generate_their_own_natural_summary(self):
        def summarize(**kwargs):
            context = json.loads(kwargs["messages"][1]["content"])
            return response("去杭州的高铁班次已经有了候选，我还在核对自驾所需时间。"
                            if "杭州" in context["request"]
                            else "正在检查循环的索引变化，尚未确认越界发生在哪一步。")

        with patch.object(progress_response, "_call_initial_model", side_effect=summarize) as model:
            travel = await generate_progress_response(self.event, self.facts, self.directory)
            code_event = SimpleNamespace(text="检查Python循环为什么越界", raw_message={})
            code = await generate_progress_response(code_event, {"phase": "tool", "activity": "执行任务步骤"}, self.directory)
        self.assertIn("杭州", travel)
        self.assertIn("索引", code)
        self.assertNotEqual(travel, code)
        self.assertEqual(model.call_count, 2)
        self.assertEqual(len(list(self.directory.glob("progress-response-*.json"))), 2)

    async def test_request_public_findings_history_and_previous_update_reach_non_thinking_model(self):
        with patch.object(progress_response, "_call_initial_model", return_value=response("还在核对路况，稍后合并交通方式的比较。")) as model:
            await generate_progress_response(self.event, self.facts, self.directory)
        request = model.call_args.kwargs
        evidence = json.loads(request["messages"][1]["content"])
        self.assertEqual(evidence["request"], self.event.text)
        for key in self.facts:
            self.assertEqual(evidence[key], self.facts[key])
        self.assertEqual(request["extra_body"], {"chat_template_kwargs": {"thinking": False, "enable_thinking": False}})
        self.assertEqual(request["task"], "orialis_initial_response")
        self.assertLessEqual(request["timeout"], 12)
        self.assertLessEqual(request["max_tokens"], 180)
        system = request["messages"][0]["content"]
        self.assertIn("不代表成功", system)
        self.assertIn("最终标记", system)
        self.assertIn("具体对象或目标", system)
        self.assertNotIn("tools", request)

    async def test_attachments_supply_only_bounded_names_not_urls_or_other_private_fields(self):
        self.event.text = "资料" * 3000
        self.event.raw_message = {
            "attachments": [{"name": "长文件名" * 100, "download_url": "private-download-url", "token": "private-token"}] * 12,
            "internal_thinking": "private-scratchpad",
        }
        with patch.object(progress_response, "_call_initial_model", return_value=response("正在处理你发来的资料。")) as model:
            await generate_progress_response(self.event, self.facts, self.directory)
        request = model.call_args.kwargs
        evidence = json.loads(request["messages"][1]["content"])
        self.assertEqual(len(evidence["request"]), 4000)
        self.assertEqual(len(evidence["attachment_names"]), 10)
        self.assertTrue(all(len(name) <= 120 for name in evidence["attachment_names"]))
        serialized = json.dumps(request)
        for private in ("private-download-url", "private-token", "private-scratchpad"):
            self.assertNotIn(private, serialized)

    async def test_same_facts_reuse_summary_and_private_cache_contains_no_raw_context(self):
        self.event.text = "PRIVATE_REQUEST_CANARY: compare travel choices"
        self.facts["public_notes"] = ["PRIVATE_PUBLIC_NOTE_CANARY"]
        model = Mock(side_effect=[response("我还在比较出行方式，等资料齐全后给你结论。"), AssertionError("must not regenerate")])
        with patch.object(progress_response, "_call_initial_model", new=model):
            first = await generate_progress_response(self.event, self.facts, self.directory)
            second = await generate_progress_response(self.event, dict(self.facts), self.directory)
        self.assertEqual(first, second)
        self.assertEqual(model.call_count, 1)
        paths = list(self.directory.glob("progress-response-*.json"))
        self.assertEqual(len(paths), 1)
        cached = json.loads(paths[0].read_text(encoding="utf-8"))
        self.assertEqual(cached["content"], first)
        self.assertEqual(cached["mode"], "off")
        self.assertEqual(cached["reasoning_tokens"], 0)
        self.assertEqual(stat.S_IMODE(paths[0].stat().st_mode), 0o600)
        self.assertNotIn("PRIVATE_REQUEST_CANARY", paths[0].read_text())
        self.assertNotIn("PRIVATE_PUBLIC_NOTE_CANARY", paths[0].read_text())
        self.assertNotIn("request", cached)

    async def test_new_confirmed_public_context_does_not_reuse_an_old_summary(self):
        model = Mock(side_effect=[response("正在核对高铁班次。"), response("高铁班次已确认，我继续核对自驾路况。")])
        with patch.object(progress_response, "_call_initial_model", new=model):
            first = await generate_progress_response(self.event, self.facts, self.directory)
            later_facts = {**self.facts, "phase": "returned", "public_notes": ["高铁班次已经确认。"]}
            later = await generate_progress_response(self.event, later_facts, self.directory)
        self.assertNotEqual(first, later)
        self.assertEqual(model.call_count, 2)

    async def test_auxiliary_failure_skips_summary_without_a_fixed_fallback_or_cache(self):
        with patch.object(progress_response, "_call_initial_model", side_effect=RuntimeError("provider unavailable")):
            result = await generate_progress_response(self.event, self.facts, self.directory)
        self.assertIsNone(result)
        self.assertEqual(list(self.directory.iterdir()), [])

    async def test_empty_overlong_and_malformed_responses_are_skipped(self):
        cases = [response(""), response("  \n "), response('""'), response("''"), response(None), response("长" * 241),
                 {}, None, {"choices": []}, {"choices": [{"message": {}}]}]
        for result in cases:
            with self.subTest(result=result), patch.object(progress_response, "_call_initial_model", return_value=result):
                self.assertIsNone(await generate_progress_response(self.event, self.facts, self.directory))
        self.assertEqual(list(self.directory.iterdir()), [])

    async def test_reasoning_content_is_rejected_even_when_visible_text_looks_valid(self):
        for key in ("reasoning", "reasoning_content"):
            with self.subTest(key=key), patch.object(progress_response, "_call_initial_model",
                                                     return_value=response("正常的公开进度。", **{key: "private reasoning"})):
                self.assertIsNone(await generate_progress_response(self.event, self.facts, self.directory))
        self.assertEqual(list(self.directory.iterdir()), [])

    async def test_positive_reasoning_token_count_is_rejected(self):
        result = response("正常的公开进度。")
        result["usage"]["completion_tokens_details"]["reasoning_tokens"] = 9
        with patch.object(progress_response, "_call_initial_model", return_value=result):
            self.assertIsNone(await generate_progress_response(self.event, self.facts, self.directory))
        self.assertEqual(list(self.directory.iterdir()), [])

    async def test_object_shaped_sdk_response_keeps_only_visible_public_text(self):
        result = SimpleNamespace(
            model="Qwen", choices=[SimpleNamespace(message=SimpleNamespace(content="还在核对交通资料。", reasoning_content=""))],
            usage=SimpleNamespace(completion_tokens_details=SimpleNamespace(reasoning_tokens=0)),
        )
        with patch.object(progress_response, "_call_initial_model", return_value=result):
            self.assertEqual(await generate_progress_response(self.event, self.facts, self.directory), "还在核对交通资料。")
        cached = json.loads(next(self.directory.glob("*.json")).read_text())
        self.assertEqual(cached["model"], "Qwen")

    async def test_blocked_sdk_does_not_block_gateway_and_timeout_has_no_late_cache(self):
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()

        def blocked(**kwargs):
            entered.set()
            try:
                release.wait(1)
                return response("迟到的进度摘要。")
            finally:
                finished.set()

        with patch.object(progress_response, "_call_initial_model", side_effect=blocked), patch.object(
            progress_response, "PROGRESS_RESPONSE_TIMEOUT", .04
        ):
            started = time.monotonic()
            task = asyncio.create_task(generate_progress_response(self.event, self.facts, self.directory))
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 1))
                main = await asyncio.wait_for(asyncio.sleep(0, result="main response ready"), .1)
                self.assertEqual(main, "main response ready")
                self.assertIsNone(await asyncio.wait_for(task, .3))
                self.assertLess(time.monotonic() - started, .3)
                self.assertEqual(list(self.directory.iterdir()), [])
            finally:
                release.set()
                self.assertTrue(await asyncio.to_thread(finished.wait, 1))
                await asyncio.gather(task, return_exceptions=True)
        self.assertEqual(list(self.directory.iterdir()), [])

    async def test_cancelled_summary_does_not_emit_or_cache_a_worker_result(self):
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()

        def blocked(**kwargs):
            entered.set()
            try:
                release.wait(1)
                return response("主回复之后才生成的进度。")
            finally:
                finished.set()

        with patch.object(progress_response, "_call_initial_model", side_effect=blocked):
            task = asyncio.create_task(generate_progress_response(self.event, self.facts, self.directory))
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 1))
                task.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await task
            finally:
                release.set()
                self.assertTrue(await asyncio.to_thread(finished.wait, 1))
                await asyncio.gather(task, return_exceptions=True)
        self.assertEqual(list(self.directory.iterdir()), [])
