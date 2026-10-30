import asyncio
import base64
from contextvars import ContextVar
import json
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

from .. import protocol
from ..memory_analysis import analyze_memory, _structured_result
from ..memory_video import VideoEvidence
from ..response_ui import MEMORY_UI_HINT


class MemoryProtocolTests(unittest.TestCase):
    def test_memory_frames_are_separate_from_chat(self):
        image = base64.b64encode(b"\xff\xd8\xfftest\xff\xd9").decode()
        request = {"version": 1, "type": "memory.analyze", "request_id": "memory-1",
                   "content": "整理这张截图", "image_base64": image}
        self.assertEqual(protocol.parse_message(protocol.encode(request)), request)
        result = {"version": 1, "type": "memory.result", "request_id": "memory-1",
                  "content": "# 标题\n\n正文"}
        self.assertEqual(protocol.parse_message(protocol.encode(result)), result)
        self.assertIn("memory.analyze", protocol.KNOWN_CAPABILITIES)

    def test_memory_limits_and_result_shape_are_validated(self):
        base = {"version": 1, "type": "memory.analyze", "request_id": "m", "content": "证据"}
        image = b"\xff\xd8\xff" + b"x" * (protocol.MAX_MEMORY_IMAGE_BYTES - 5) + b"\xff\xd9"
        self.assertEqual(protocol.parse_message({**base, "image_base64": base64.b64encode(image).decode()})["content"], "证据")
        for change in ({"request_id": "x" * 161}, {"content": "中" * 33334},
                       {"source_urls": ["https://example.test/"] * 33},
                       {"source_urls": ["file:///private/capture"]},
                       {"image_base64": "not-base64"}, {"image_base64": ""},
                       {"image_base64": base64.b64encode(b"PNG").decode()},
                       {"image_base64": base64.b64encode(image + b"x").decode()}):
            with self.subTest(change=list(change)), self.assertRaises(protocol.ProtocolError):
                protocol.parse_message({**base, **change})
        result = {"version": 1, "type": "memory.result", "request_id": "m"}
        for change in ({}, {"content": ""}, {"content": "ok", "error": "bad"}, {"content": "中" * 33334}):
            with self.subTest(change=list(change)), self.assertRaises(protocol.ProtocolError):
                protocol.parse_message({**result, **change})
        for change in ({"category": "unknown"}, {"video_status": "downloaded"},
                       {"source_url": "file:///etc/passwd"}, {"video_error": "中" * 1334}):
            with self.subTest(change=change), self.assertRaises(protocol.ProtocolError):
                protocol.parse_message({**result, "content": "# 标题\n\n正文", **change})


class MemoryCompletionTests(unittest.TestCase):
    def test_memory_ui_survives_outer_json_and_background_result_transport(self):
        document = {"version": 1, "title": "关键结论", "fallback": "高质量数据决定训练质量。",
                    "blocks": [{"type": "facts", "items": [
                        {"label": "训练数据", "value": "高质量数据决定训练质量。"}]}]}
        fence = "```orialis-ui\n" + json.dumps(document, ensure_ascii=False) + "\n```"
        summary = "# 训练要点\n\n优先检查数据质量。\n\n" + fence
        video_summary = "视频强调训练数据质量。\n\n" + fence
        source = "https://www.bilibili.com/video/BV1d8pU6xEZX"
        for video in (VideoEvidence(), VideoEvidence(source_url=source, status="analyzed",
                                                     captions="[3.0s] 高质量数据决定训练质量。")):
            with self.subTest(video_status=video.status):
                payload = json.dumps({"summary": summary, "category": "ai",
                                      "video_summary": video_summary}, ensure_ascii=False)
                completion = AsyncMock(return_value={"choices": [{"message": {
                    "content": "```json\n" + payload + "\n```"}}]})
                with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video), \
                     patch.dict(sys.modules, {"agent.auxiliary_client": SimpleNamespace(async_call_llm=completion)}):
                    result = asyncio.run(analyze_memory("字幕证据", source_urls=[source]))
                self.assertEqual(result["content"], summary)
                if video.status == "analyzed":
                    self.assertEqual(result["video_summary"], video_summary)
                else:
                    self.assertNotIn("video_summary", result)
                frame = {"version": 1, "type": "memory.result", "request_id": "memory-ui", **result}
                self.assertEqual(protocol.parse_message(protocol.encode(frame)), frame)

    def test_fenced_structured_categories_are_parsed_and_invalid_classification_fails(self):
        self.assertEqual(_structured_result('```json\n{"summary":"# 标题\\n\\n正文","category":"ai"}\n```')["category"], "ai")
        for value in ({"summary": "# 标题\n\n正文", "category": "AI"},
                      {"summary": "# 只有标题", "category": "other"},
                      {"summary": "正文", "category": "ai"}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                _structured_result(json.dumps(value))

    def test_actual_caption_evidence_drives_video_summary_and_model_cannot_replace_source(self):
        source = "https://b23.tv/Original?signature=abc%2Bdef"
        video = VideoEvidence(source_url=source, status="analyzed", captions="[3.0s] 训练模型需要高质量数据")
        completion = AsyncMock(return_value={"summary": "# AI视频\n\n解释训练数据。", "category": "ai",
                                            "video_summary": "字幕解释训练数据的重要性。", "source_url": "https://invented.test/"})
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video), \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("原始分享证据", source_urls=[source]))
        self.assertEqual(result["source_url"], source)
        self.assertEqual(result["video_status"], "analyzed")
        self.assertIn("字幕解释", result["video_summary"])
        context = completion.call_args.args[0]
        self.assertIn("训练模型需要高质量数据", context[1]["text"])

    def test_storyboard_images_reach_the_visual_model_and_missing_summary_is_retryable(self):
        video = VideoEvidence(status="analyzed", frames=[(30, "FRAME_JPEG"), (60, "SECOND_JPEG")])
        completion = AsyncMock(return_value={"summary": "# 视频\n\n画面内容。", "category": "other"})
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video), \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("BV1d8pU6xEZX"))
        images = [part["image_url"]["url"] for part in completion.call_args.args[0] if part["type"] == "image_url"]
        self.assertEqual(images, ["data:image/jpeg;base64,FRAME_JPEG", "data:image/jpeg;base64,SECOND_JPEG"])
        self.assertEqual(result["video_status"], "unavailable")
        self.assertNotIn("video_summary", result)

    def test_joint_caption_and_full_frame_sequence_reach_model(self):
        captions = "[0.0s] 开始演示\n[300.0s] 最终结论"
        video = VideoEvidence(status="analyzed", captions=captions,
                              frames=[(index * 13, f"JPEG_{index}") for index in range(24)])
        completion = AsyncMock(return_value={"choices": [{"message": {"content": json.dumps({
            "summary": "# 演示\n\n演示结论", "category": "ai", "video_summary": "[300s] 最终结论",
        })}}]})
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video), \
             patch.dict(sys.modules, {"agent.auxiliary_client": SimpleNamespace(async_call_llm=completion)}):
            result = asyncio.run(analyze_memory("BV1d8pU6xEZX"))
        kwargs = completion.call_args.kwargs
        evidence = kwargs["messages"][1]["content"]
        context = json.loads(evidence[1]["text"].partition("：\n")[2])
        self.assertEqual(context["captions"], captions)
        images = [item["image_url"]["url"] for item in evidence if item["type"] == "image_url"]
        self.assertEqual(images, [f"data:image/jpeg;base64,JPEG_{index}" for index in range(24)])
        self.assertIn("[300s]", result["video_summary"])
        prompt = kwargs["messages"][0]["content"]
        self.assertIn("按时间顺序", prompt)
        self.assertIn("区分作者陈述、可见事实", prompt)
        self.assertIn("证据缺口会影响结论时", prompt)
        self.assertIn("先写核心结论", prompt)
        self.assertIn("按重要性", prompt)

    def test_no_media_evidence_cannot_be_promoted_to_analyzed_by_model(self):
        video = VideoEvidence(status="unavailable", error="平台未提供视频内容")
        completion = AsyncMock(return_value={"summary": "# 标题\n\n截图正文。", "category": "ai", "video_summary": "模型声称的视频概述"})
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video), \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("BV1d8pU6xEZX"))
        self.assertEqual(result["video_status"], "unavailable")
        self.assertNotIn("video_summary", result)

    def test_video_screenshot_without_verifiable_id_is_explicitly_unavailable(self):
        completion = AsyncMock(return_value={"summary": "# 截图\n\n播放器画面。", "category": "other", "video_detected": True})
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=VideoEvidence()), \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("用户截图", "SCREEN"))
        self.assertEqual(result["video_status"], "unavailable")
        self.assertIn("原始视频链接", result["video_error"])
        self.assertNotIn("source_url", result)

    def test_screenshot_ocr_uses_only_exact_bv_for_platform_verification(self):
        completion = AsyncMock(side_effect=[
            {"summary": "# 截图\n\n原始截图。", "category": "ai", "detected_bvid": "BV1d8pU6xEZX"},
            {"summary": "# 视频\n\n画面摘要。", "category": "ai", "video_summary": "实际画面展示模型界面。"},
        ])
        video = VideoEvidence(status="analyzed", frames=[(20, "JPEG")], source_url="https://www.bilibili.com/video/BV1d8pU6xEZX")
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video) as collect, \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("这是用户截图", "SCREEN"))
        self.assertEqual(collect.call_args.kwargs["detected_bvid"], "BV1d8pU6xEZX")
        self.assertEqual(result["video_status"], "analyzed")

    def test_screenshot_visible_title_and_uploader_are_passed_to_platform_verification(self):
        first = {"summary": "# 截图\n\nDSH视频。", "category": "ai", "video_detected": True,
                 "video_platform": "bilibili", "video_title": "人工智能模型演示视频", "video_uploader": "示例UP"}
        completion = AsyncMock(side_effect=[first, {"summary": "# 视频\n\n画面摘要。", "category": "ai", "video_summary": "实际视频画面。"}])
        video = VideoEvidence(status="analyzed", frames=[(20, "JPEG")], source_url="https://www.bilibili.com/video/BV1d8pU6xEZX")
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video) as collect, \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("截图可见标题和UP", "SCREEN"))
        self.assertEqual(collect.call_args.kwargs["search_title"], first["video_title"])
        self.assertEqual(collect.call_args.kwargs["search_uploader"], first["video_uploader"])
        self.assertEqual(result["source_url"], video.source_url)

    def test_other_platform_or_missing_uploader_cannot_start_bilibili_title_search(self):
        for platform, uploader in [("douyin", "示例UP"), ("bilibili", None)]:
            completion = AsyncMock(return_value={"summary": "# 截图\n\n视频画面。", "category": "other",
                "video_detected": True, "video_platform": platform, "video_title": "视频标题内容", "video_uploader": uploader})
            with self.subTest(platform=platform), patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=VideoEvidence()) as collect, \
                 patch("integrations.hermes.orialis.memory_analysis._complete", completion):
                asyncio.run(analyze_memory("截图", "SCREEN"))
            self.assertIsNone(collect.call_args.kwargs["search_title"])

    def test_second_model_failure_preserves_initial_screenshot_summary(self):
        completion = AsyncMock(side_effect=[
            {"summary": "# 截图\n\n截图摘要。", "category": "other", "detected_bvid": "BV1d8pU6xEZX"},
            RuntimeError("SECRET"),
        ])
        video = VideoEvidence(status="analyzed", frames=[(20, "JPEG")])
        with patch("integrations.hermes.orialis.memory_analysis.collect_video", return_value=video), \
             patch("integrations.hermes.orialis.memory_analysis._complete", completion):
            result = asyncio.run(analyze_memory("截图", "SCREEN"))
        self.assertEqual(result["content"], "# 截图\n\n截图摘要。")
        self.assertEqual(result["video_status"], "unavailable")
        self.assertNotIn("SECRET", result["video_error"])

    def test_dict_response_and_text_only_evidence_are_supported(self):
        completion = AsyncMock(return_value={"choices": [{"message": {"content": json.dumps({"summary": "# 分享\n\n正文", "category": "other"})}}]})
        with patch.dict(sys.modules, {"agent.auxiliary_client": SimpleNamespace(async_call_llm=completion)}):
            self.assertEqual(asyncio.run(analyze_memory("分享内容")), {"content": "# 分享\n\n正文", "category": "other", "video_status": "none"})
        self.assertEqual(completion.call_args.kwargs["messages"][1]["content"][0], {"type": "text", "text": "分享内容"})

    def test_direct_completion_passes_evidence_without_tools_or_chat_session(self):
        completion = AsyncMock(return_value=SimpleNamespace(choices=[
            SimpleNamespace(message=SimpleNamespace(content=json.dumps({"summary": "# 收藏\n\n内容摘要", "category": "ai"}))),
        ]))
        with patch.dict(sys.modules, {"agent.auxiliary_client": SimpleNamespace(async_call_llm=completion)}):
            self.assertEqual(asyncio.run(analyze_memory("屏幕证据", "JPEG")), {"content": "# 收藏\n\n内容摘要", "category": "ai", "video_status": "none"})
        kwargs = completion.call_args.kwargs
        self.assertEqual(kwargs["task"], "vision")
        system = kwargs["messages"][0]["content"]
        self.assertTrue(system.endswith(MEMORY_UI_HINT))
        self.assertIn("仍只输出一个外层 JSON 对象", system)
        self.assertIn("summary 必须先保留 # 标题", system)
        for shape in ("facts:", "steps:", "comparison:", "accordion:", "table:"):
            self.assertIn(shape, system)
        self.assertIn("不要输出 choices、form、actions、agenda", system)
        self.assertNotIn("tools", kwargs)
        self.assertNotIn("session", kwargs)
        evidence = kwargs["messages"][1]["content"]
        self.assertEqual(evidence[0], {"type": "text", "text": "屏幕证据"})
        self.assertEqual(evidence[1]["image_url"]["url"], "data:image/jpeg;base64,JPEG")

    def test_empty_or_reasoning_only_completion_is_not_an_analysis_result(self):
        for content in (None, " ", "x" * 100001):
            completion = AsyncMock(return_value=SimpleNamespace(choices=[
                SimpleNamespace(message=SimpleNamespace(content=content, reasoning_content="private reasoning")),
            ]))
            with self.subTest(content_type=type(content)), patch.dict(sys.modules, {
                "agent.auxiliary_client": SimpleNamespace(async_call_llm=completion),
            }), self.assertRaises(ValueError):
                asyncio.run(analyze_memory("证据"))


class MemorySecretScopeTests(unittest.TestCase):
    def scope_modules(self, current, owner):
        def install(secrets, *, profile_home):
            return current.set((secrets, profile_home))

        api = SimpleNamespace(
            is_multiplex_active=Mock(return_value=True),
            current_secret_scope=current.get,
            set_secret_scope=Mock(side_effect=install),
            reset_secret_scope=Mock(side_effect=current.reset),
        )
        modules = {
            "agent": SimpleNamespace(secret_scope=api),
            "agent.secret_scope": api,
            "hermes_constants": SimpleNamespace(get_hermes_home=lambda: "/tmp/memory-profile"),
            "tui_gateway.launch_profile_policy": SimpleNamespace(owner_secret_scope=owner),
        }
        return api, modules

    def test_background_scope_uses_profile_home_and_resets_after_success_or_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail):
                current = ContextVar("memory_test_scope", default=None)
                secrets = {"VISION_API_KEY": "test-only"}
                owner = Mock(return_value=secrets)
                api, modules = self.scope_modules(current, owner)

                async def inner(content, image, urls):
                    self.assertEqual(current.get(), (secrets, "/tmp/memory-profile"))
                    self.assertEqual((content, image, urls), ("evidence", "JPEG", ["https://example.com"]))
                    if fail:
                        raise ValueError("provider-private-detail")
                    return {"content": "# Result\n\nBody"}

                async def run():
                    if fail:
                        with self.assertLogs("integrations.hermes.orialis.memory_analysis", level="WARNING") as logs:
                            with self.assertRaises(ValueError):
                                await analyze_memory("evidence", "JPEG", ["https://example.com"])
                        self.assertNotIn("provider-private-detail", "\n".join(logs.output))
                    else:
                        self.assertEqual(await analyze_memory("evidence", "JPEG", ["https://example.com"]),
                                         {"content": "# Result\n\nBody"})
                    self.assertIsNone(current.get())

                with patch.dict(sys.modules, modules), patch(
                    "integrations.hermes.orialis.memory_analysis._analyze_memory", side_effect=inner,
                ):
                    asyncio.run(run())
                self.assertEqual(str(owner.call_args.args[0]), "/tmp/memory-profile")
                api.set_secret_scope.assert_called_once_with(secrets, profile_home="/tmp/memory-profile")
                api.reset_secret_scope.assert_called_once()

    def test_older_hermes_launch_secret_scope_helper_is_supported(self):
        current = ContextVar("legacy_memory_scope", default=None)
        secrets = {"VISION_API_KEY": "legacy-test-only"}
        launch = Mock(return_value=secrets)
        api, modules = self.scope_modules(current, launch)
        modules["tui_gateway.launch_profile_policy"] = SimpleNamespace(launch_secret_scope=launch)

        async def inner(*args):
            self.assertEqual(current.get(), (secrets, "/tmp/memory-profile"))
            return {"content": "# Legacy\n\nBody"}

        async def run():
            self.assertEqual(await analyze_memory("evidence"), {"content": "# Legacy\n\nBody"})
            self.assertIsNone(current.get())

        with patch.dict(sys.modules, modules), patch(
            "integrations.hermes.orialis.memory_analysis._analyze_memory", side_effect=inner,
        ):
            asyncio.run(run())
        launch.assert_called_once()
        self.assertEqual(str(launch.call_args.args[0]), "/tmp/memory-profile")
        api.set_secret_scope.assert_called_once_with(secrets, profile_home="/tmp/memory-profile")
        api.reset_secret_scope.assert_called_once()

    def test_existing_scope_is_preserved_and_owner_credentials_are_not_loaded(self):
        current = ContextVar("existing_memory_scope", default=None)
        owner = Mock(side_effect=AssertionError("must not load owner credentials"))
        api, modules = self.scope_modules(current, owner)
        existing = {"scope": "caller"}

        async def inner(*args):
            self.assertIs(current.get(), existing)
            return {"content": "# Result\n\nBody"}

        async def run():
            token = current.set(existing)
            try:
                await analyze_memory("evidence")
                self.assertIs(current.get(), existing)
            finally:
                current.reset(token)

        with patch.dict(sys.modules, modules), patch(
            "integrations.hermes.orialis.memory_analysis._analyze_memory", side_effect=inner,
        ):
            asyncio.run(run())
        owner.assert_not_called()
        api.set_secret_scope.assert_not_called()
        api.reset_secret_scope.assert_not_called()
