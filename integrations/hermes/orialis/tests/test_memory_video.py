import base64
import io
import json
import os
from pathlib import Path
import stat
import struct
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

from ..memory_video import (PublicBiliHTTP, VideoUnavailable, collect_video, _allowed_url, _entries,
                           load_bili_credentials, bili_credential_path)

BVID = "BV1d8pU6xEZX"
URL = f"https://www.bilibili.com/video/{BVID}/?p=2&share_session_id=signed%2Bvalue"


class FakeHTTP:
    def __init__(self, captions=True, frames=True):
        self.calls = []
        self.captions, self.frames = captions, frames
        image = Image.new("RGB", (30, 10))
        for x in range(30):
            for y in range(10):
                image.putpixel((x, y), [(230, 0, 0), (0, 230, 0), (0, 0, 230)][x // 10])
        output = io.BytesIO()
        image.save(output, format="PNG")
        self.sheet = output.getvalue()

    def resolve(self, url):
        self.calls.append(("resolve", url))
        return URL

    def data(self, path, params):
        self.calls.append((path, params))
        if path.endswith("/view"):
            return {"bvid": BVID, "aid": 1, "title": "AI模型演示", "duration": 100,
                    "pages": [{"cid": 101, "duration": 40}, {"cid": 202, "duration": 60}]}
        if path.endswith("/v2"):
            return {"subtitle": {"subtitles": [{"lan": "zh-CN", "subtitle_url": "//aisubtitle.hdslb.com/caption.json"}] if self.captions else []}}
        if path.endswith("/videoshot"):
            return {"image": ["//i0.hdslb.com/sheet.png"], "index": [0, 30, 60] if self.frames else [],
                    "img_x_size": 10, "img_y_size": 10}
        raise AssertionError(path)

    def fetch(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if "caption" in url:
            return json.dumps({"body": [{"from": 0, "content": "模型通过训练学习特征"}, {"from": 12.5, "content": "展示推理效果"}]}).encode(), url
        if "sheet" in url:
            return self.sheet, url
        if "pvdata" in url:
            return struct.pack(">3H", 0, 30, 60), url
        raise AssertionError(url)


class VideoEvidenceTests(unittest.TestCase):
    def caption_track(self, body, duration=157):
        http = FakeHTTP()
        original_data, original_fetch = http.data, http.fetch
        def data(path, params):
            value = original_data(path, params)
            if path.endswith("/view"):
                value["pages"][1]["duration"] = duration
            return value
        def fetch(url, **kwargs):
            if "caption" in url:
                http.calls.append((url, kwargs))
                return json.dumps({"body": body}).encode(), url
            return original_fetch(url, **kwargs)
        http.data, http.fetch = data, fetch
        return http

    def test_157_second_video_rejects_entire_180_7_second_wrong_caption_track(self):
        http = self.caption_track([
            {"from": 0, "to": 4.2, "content": "这款手表的显示效果"},
            {"from": 175.1, "to": 180.7, "content": "手表使用总结"},
        ])
        evidence = collect_video([URL], http=http)
        self.assertEqual(evidence.captions, "")
        self.assertTrue(evidence.frames)
        self.assertEqual(evidence.status, "analyzed")
        self.assertTrue(any(path == "/x/player/videoshot" for path, _ in http.calls))
        self.assertNotIn("手表", json.dumps(evidence.model_context(), ensure_ascii=False))

    def test_valid_caption_rounding_tolerance_keeps_subtitles_without_storyboard(self):
        http = self.caption_track([
            {"from": 0, "to": 3.2, "content": "展示插件设置"},
            {"from": 155.5, "to": 159.9, "content": "演示结束"},
        ])
        evidence = collect_video([URL], http=http)
        self.assertIn("展示插件设置", evidence.captions)
        self.assertIn("演示结束", evidence.captions)
        self.assertFalse(evidence.frames)
        self.assertFalse(any(path == "/x/player/videoshot" for path, _ in http.calls))

    def test_music_markers_use_storyboard_but_do_not_remove_real_speech(self):
        body = [{"from": 0.8, "to": 3.1, "content": "♪ 音乐 ♪"},
                {"from": 39.5, "to": 44.5, "content": "♪ 音乐 ♪"}]
        music = collect_video([URL], http=self.caption_track(body))
        self.assertEqual(music.captions, "")
        self.assertTrue(music.frames)
        self.assertEqual(music.status, "analyzed")
        speech = collect_video([URL], http=self.caption_track([
            *body, {"from": 50, "to": 55, "content": "让DSH按关键词搜索视频"},
        ]))
        self.assertIn("按关键词搜索视频", speech.captions)
        self.assertFalse(speech.frames)

    def test_invalid_times_anywhere_in_track_discard_all_caption_lines(self):
        for segment in [
            {"from": float("nan"), "to": 10},
            {"from": 0, "to": float("inf")},
            {"from": -1, "to": 2},
            {"from": 0, "to": -1},
            {"from": 10, "to": 9},
            {"from": 170, "to": 171},
        ]:
            with self.subTest(segment=segment):
                body = [{"from": 0, "to": 1, "content": "不要保留的早期句子"}] * 3000
                http = self.caption_track([*body, {**segment, "content": "越界句"}])
                evidence = collect_video([URL], http=http)
                self.assertEqual(evidence.captions, "")
                self.assertTrue(evidence.frames)

    def test_subtitles_first_preserves_exact_signed_source_and_selected_part(self):
        http = FakeHTTP()
        evidence = collect_video([URL], http=http)
        self.assertEqual(evidence.status, "analyzed")
        self.assertEqual(evidence.source_url, URL)
        self.assertIn("模型通过训练学习特征", evidence.captions)
        self.assertEqual(evidence.frames, [])
        self.assertEqual(evidence.metadata["part"], 2)
        player = next(params for path, params in http.calls if path == "/x/player/v2")
        self.assertEqual(player["cid"], 202)
        self.assertFalse(any(path == "/x/player/videoshot" for path, _ in http.calls))

    def test_storyboard_fallback_is_actual_cropped_jpeg_evidence(self):
        http = FakeHTTP(captions=False)
        evidence = collect_video([URL], http=http)
        self.assertEqual(evidence.status, "analyzed")
        self.assertEqual(evidence.captions, "")
        self.assertGreaterEqual(len(evidence.frames), 2)
        colors = []
        for _, encoded in evidence.frames:
            with Image.open(io.BytesIO(base64.b64decode(encoded))) as image:
                self.assertEqual(image.format, "JPEG")
                self.assertEqual(image.size, (10, 10))
                colors.append(max(range(3), key=lambda channel: image.getpixel((5, 5))[channel]))
        self.assertGreater(len(set(colors)), 1)
        self.assertIn("抽样帧", evidence.model_context()["limitations"])

    def test_pvdata_index_fallback_decodes_real_big_endian_timestamps(self):
        http = FakeHTTP(captions=False)
        original = http.data
        def data(path, params):
            result = original(path, params)
            if path.endswith("/videoshot"):
                result.update(index=[], pvdata="//i0.hdslb.com/pvdata.bin")
            return result
        http.data = data
        evidence = collect_video([URL], http=http)
        self.assertEqual(evidence.status, "analyzed")
        self.assertTrue(evidence.frames)

    def test_title_only_is_never_video_understanding_and_other_platform_is_explicit(self):
        evidence = collect_video([URL], http=FakeHTTP(captions=False, frames=False))
        self.assertEqual(evidence.status, "unavailable")
        self.assertFalse(evidence.frames or evidence.captions)
        self.assertIn("字幕", evidence.error)
        other = collect_video(["https://youtu.be/Original"], http=FakeHTTP())
        self.assertEqual(other.status, "unavailable")
        self.assertIn("仅支持哔哩哔哩", other.error)

    def test_exact_ocr_bv_requires_matching_platform_info(self):
        evidence = collect_video([], detected_bvid=BVID, http=FakeHTTP())
        self.assertEqual(evidence.source_url, f"https://www.bilibili.com/video/{BVID}")
        self.assertEqual(evidence.status, "analyzed")
        self.assertEqual(collect_video([], detected_bvid="猜测的编号", http=FakeHTTP()).status, "none")
        mismatch = FakeHTTP()
        original = mismatch.data
        mismatch.data = lambda path, params: {**original(path, params), "bvid": "BV1xx411c7mD"}
        self.assertEqual(collect_video([], detected_bvid=BVID, http=mismatch).status, "unavailable")

    def test_short_url_is_resolved_but_original_link_retained(self):
        short = "https://b23.tv/Original?share=keep%2Bthis"
        evidence = collect_video([short], http=FakeHTTP())
        self.assertEqual(evidence.status, "analyzed")
        self.assertEqual(evidence.source_url, short)
        self.assertEqual(evidence.metadata["part"], 2)

    def test_bad_part_is_not_silently_replaced_with_first_part(self):
        evidence = collect_video([URL.replace("p=2", "p=9")], http=FakeHTTP())
        self.assertEqual(evidence.status, "unavailable")
        self.assertFalse(evidence.captions or evidence.frames)

    def test_seconds_for_long_video_are_not_mistaken_for_milliseconds(self):
        self.assertEqual(_entries({"index": [0, 22000]}, 23000), [(0, 0), (22000, 1)])
        self.assertEqual(_entries({"index": [0, 60000]}, 60), [(0, 0), (60, 1)])


class PublicFetchTests(unittest.TestCase):
    def test_only_expected_hosts_public_addresses_and_https_are_fetched(self):
        for url in ("https://127.0.0.1/video", "https://bilibili.com.evil.test/video", "https://api.bilibili.com@127.0.0.1/", "file:///etc/passwd", "https://api.bilibili.com:444/"):
            with self.subTest(url=url), self.assertRaises(VideoUnavailable):
                _allowed_url(url, media=True)
        with patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("127.0.0.1", 443))]), patch("http.client.HTTPSConnection") as connection:
            with self.assertRaises(VideoUnavailable):
                PublicBiliHTTP().fetch("https://api.bilibili.com/x/test")
            connection.assert_not_called()

    def test_redirect_target_is_validated_before_connecting(self):
        class Response:
            status = 302
            def getheader(self, name):
                return "https://127.0.0.1/private" if name == "Location" else None
        with patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("93.184.216.34", 443))]), patch("http.client.HTTPSConnection") as connection:
            connection.return_value.getresponse.return_value = Response()
            with self.assertRaises(VideoUnavailable):
                PublicBiliHTTP().fetch("https://b23.tv/test")
            self.assertEqual(connection.call_count, 1)

    def test_short_redirect_does_not_download_or_require_the_final_html_page(self):
        class Response:
            status = 302
            def getheader(self, name):
                return URL if name == "Location" else None
        with patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("93.184.216.34", 443))]), patch("http.client.HTTPSConnection") as connection:
            connection.return_value.getresponse.return_value = Response()
            self.assertEqual(PublicBiliHTTP().resolve("https://b23.tv/test"), URL)
            self.assertEqual(connection.call_count, 1)

    def test_response_size_is_bounded(self):
        class Response:
            status = 200
            def getheader(self, name):
                return "10000000" if name == "Content-Length" else None
        with patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("93.184.216.34", 443))]), patch("http.client.HTTPSConnection") as connection:
            connection.return_value.getresponse.return_value = Response()
            with self.assertRaises(VideoUnavailable):
                PublicBiliHTTP().fetch("https://api.bilibili.com/x/test", limit=100)


class DedicatedCredentialTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "orialis-memory" / "bili_credential.json"
        environment = patch.dict(os.environ, {"HERMES_HOME": self.directory.name, "ORIALIS_BILI_CREDENTIAL_FILE": ""})
        environment.start()
        self.addCleanup(environment.stop)

    def write(self, value, mode=0o600):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(value))
        self.path.chmod(mode)

    def test_default_missing_file_stays_anonymous_and_explicit_missing_is_actionable(self):
        self.assertEqual(load_bili_credentials(), {})
        with patch.dict(os.environ, {"ORIALIS_BILI_CREDENTIAL_FILE": str(self.path)}), self.assertRaisesRegex(VideoUnavailable, "不存在"):
            load_bili_credentials()

    def test_production_home_default_matches_login_destination(self):
        with patch.dict(os.environ, {"HERMES_HOME": "/home/hermes/.hermes", "ORIALIS_BILI_CREDENTIAL_FILE": ""}):
            self.assertEqual(bili_credential_path(), (Path("/home/hermes/.hermes/orialis-memory/bili_credential.json"), False))

    def test_only_private_dedicated_sdk_cookie_mapping_is_read(self):
        self.write({"SESSDATA": "test%2Csession", "bili_jct": "test-csrf", "buvid3": "visitor-three", "buvid4": "visitor-four", "DedeUserID": "123"})
        self.assertEqual(load_bili_credentials()["buvid4"], "visitor-four")
        self.path.chmod(0o644)
        with self.assertRaisesRegex(VideoUnavailable, "600"):
            load_bili_credentials()

    def test_unknown_fields_header_injection_and_read_failures_never_echo_secrets(self):
        for value in ({"SESSDATA": "SECRET", "unrelated_app_cookie": "SECRET"},
                      {"SESSDATA": "SECRET\r\nX-Evil: true"}, {"SESSDATA": "SECRET; injected=true"},
                      {"SESSDATA": "SECRET,other=value"}, {"SESSDATA": 'SECRET"quoted'}):
            self.write(value)
            with self.assertRaises(VideoUnavailable) as error:
                load_bili_credentials()
            self.assertNotIn("SECRET", str(error.exception))
        with patch("os.open", side_effect=PermissionError("SECRET path")):
            with self.assertRaises(VideoUnavailable) as error:
                load_bili_credentials()
            self.assertNotIn("SECRET", str(error.exception))

    def test_symlink_and_non_regular_files_are_not_read(self):
        target = Path(self.directory.name) / "other-app.json"
        target.write_text('{"SESSDATA":"UNRELATED"}')
        target.chmod(0o600)
        self.path.parent.mkdir(parents=True)
        self.path.symlink_to(target)
        with self.assertRaises(VideoUnavailable):
            load_bili_credentials()

    def test_invalid_dedicated_credentials_keep_screen_video_retryable(self):
        self.write({"SESSDATA": "SECRET", "unexpected": "SECRET"})
        with patch.object(PublicBiliHTTP, "fetch") as fetch:
            result = collect_video([URL])
        fetch.assert_not_called()
        self.assertEqual(result.status, "unavailable")
        self.assertIn("专用二维码", result.error)
        self.assertNotIn("SECRET", result.error)

    def test_bad_bili_credentials_do_not_affect_screen_only_or_other_web_sources(self):
        self.write({"SESSDATA": "SECRET", "unexpected": "SECRET"})
        with patch.dict(os.environ, {"ORIALIS_BILI_CREDENTIAL_FILE": str(self.path)}), \
             patch("integrations.hermes.orialis.memory_video.load_bili_credentials", side_effect=AssertionError("must not load")):
            self.assertEqual(collect_video([]).status, "none")
            self.assertEqual(collect_video(["https://example.test/article"]).status, "none")
            self.assertEqual(collect_video(["https://youtu.be/Original"]).status, "unavailable")

    def test_cookies_are_scoped_per_redirect_and_never_sent_to_shortlink_or_cdn(self):
        self.write({"SESSDATA": "PRIVATE_SESSION", "bili_jct": "PRIVATE_CSRF"})

        class Response:
            def __init__(self, status=200, location=None):
                self.status, self.location = status, location
            def getheader(self, name):
                return self.location if name == "Location" else None
            def read(self, count):
                return b""

        for start, responses, expected in (
            ("https://api.bilibili.com/x/test", [Response()], [True]),
            ("https://b23.tv/test", [Response()], [False]),
            ("https://i0.hdslb.com/a.jpg", [Response()], [False]),
            ("https://api.bilibili.com/x/test", [Response(302, "https://i0.hdslb.com/a.jpg"), Response()], [True, False]),
            ("https://b23.tv/test", [Response(302, "https://www.bilibili.com/video/" + BVID), Response()], [False, True]),
        ):
            with self.subTest(start=start, expected=expected), \
                 patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("93.184.216.34", 443))]), \
                 patch("http.client.HTTPSConnection") as connection:
                connection.return_value.getresponse.side_effect = responses
                PublicBiliHTTP().fetch(start, media=True)
                sent = [call.kwargs["headers"] for call in connection.return_value.request.call_args_list]
                self.assertEqual(["Cookie" in headers for headers in sent], expected)
                for headers in sent:
                    if "Cookie" in headers:
                        self.assertIn("SESSDATA=PRIVATE_SESSION", headers["Cookie"])

    def test_auth_and_risk_api_errors_remain_distinct_without_raw_messages(self):
        client = PublicBiliHTTP()
        for code, expected in ((-101, "登录状态"), (-412, "限制当前服务器")):
            with self.subTest(code=code), patch.object(client, "fetch", return_value=(json.dumps({"code": code, "message": "SECRET"}).encode(), "")):
                with self.assertRaisesRegex(VideoUnavailable, expected) as error:
                    client.data("/x/test", {})
                self.assertNotIn("SECRET", str(error.exception))
