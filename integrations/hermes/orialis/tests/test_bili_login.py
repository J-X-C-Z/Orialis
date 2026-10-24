import asyncio
import contextlib
from enum import Enum
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import AsyncMock, Mock, patch

from ..bili_login import login, write_credentials, _write_private
from ..memory_video import VideoUnavailable


class CredentialWriterTests(unittest.TestCase):
    def test_atomic_private_writer_keeps_only_expected_cookie_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private" / "bili_credential.json"
            fields = write_credentials(path, {"SESSDATA": "test-session", "buvid3": "issued-visitor", "buvid4": ""})
            self.assertEqual(fields, ["SESSDATA", "buvid3"])
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
            self.assertEqual(json.loads(path.read_text()), {"SESSDATA": "test-session", "buvid3": "issued-visitor"})
            with patch("os.replace", side_effect=OSError("simulated disk failure")), self.assertRaises(OSError):
                write_credentials(path, {"SESSDATA": "new-session"})
            self.assertEqual(json.loads(path.read_text())["SESSDATA"], "test-session")
            self.assertFalse(list(path.parent.glob(".bili_credential.json.*")))

    def test_writer_rejects_symlink_and_unknown_cookie_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "unrelated"
            target.write_text("keep")
            link = Path(directory) / "credential"
            link.symlink_to(target)
            with self.assertRaises(VideoUnavailable):
                write_credentials(link, {"SESSDATA": "new-session"})
            self.assertEqual(target.read_text(), "keep")
            with self.assertRaises(VideoUnavailable):
                write_credentials(Path(directory) / "credential.json", {"SESSDATA": "session", "ac_time_value": "not-allowed"})


class LoginFlowTests(unittest.TestCase):
    def sdk(self, responses, destination):
        from urllib.parse import quote
        class Credential:
            def __init__(self, sessdata=None, bili_jct=None, buvid3=None, buvid4=None, dedeuserid=None):
                self.cookies = {"SESSDATA": sessdata if sessdata and "%" in sessdata else quote(sessdata or ""),
                    "bili_jct": bili_jct or "", "buvid3": buvid3 or "", "buvid4": buvid4 or "", "DedeUserID": dedeuserid or ""}
            def get_cookies(self):
                return self.cookies
        async def request(**kwargs):
            if destination.exists() and destination.read_text() != "keep-old":
                raise AssertionError("saved before successful response")
            self.assertFalse(kwargs["allow_redirects"])
            return responses.pop(0)
        client = SimpleNamespace(request=AsyncMock(side_effect=request), close=AsyncMock())
        sdk = ModuleType("bilibili_api")
        sdk.__path__ = []
        sdk.Credential = Credential
        sdk.request_settings = SimpleNamespace(set_timeout=Mock(), set_wbi_retry_times=Mock())
        utils = ModuleType("bilibili_api.utils")
        utils.__path__ = []
        network = ModuleType("bilibili_api.utils.network")
        network.HEADERS = {"User-Agent": "SDK test"}
        network.get_client = lambda: client
        network.get_buvid = AsyncMock(return_value=("SDK_VISITOR3", "SDK_VISITOR4"))
        def save(target, format=None):
            target.write(b"\x89PNG\r\n\x1a\nTEST")
        qr = SimpleNamespace(make=lambda value: SimpleNamespace(save=save))
        return {"bilibili_api": sdk, "bilibili_api.utils": utils,
                "bilibili_api.utils.network": network, "qrcode": qr}, client

    def response(self, code=0, cookies=None, generated=False):
        data = {"qrcode_key": "PRIVATE_QR_KEY", "url": "https://passport.bilibili.com/login?key=PRIVATE_QR_KEY"} if generated else {"code": code, "url": "https://passport.biligame.com/crossDomain?gourl=home"}
        return SimpleNamespace(code=200, cookies=cookies or {}, json=lambda: {"code": 0, "data": data})

    def test_web_success_reads_response_cookies_even_when_url_has_no_session(self):
        with tempfile.TemporaryDirectory() as directory:
            destination, qr = Path(directory) / "credential.json", Path(directory) / "qr.png"
            responses = [self.response(generated=True), self.response(86101), self.response(86090),
                         self.response(0, {"SESSDATA": "RAW,SESSION", "bili_jct": "CSRF_SECRET", "DedeUserID": "123", "sid": "NOT_SAVED"})]
            modules, client = self.sdk(responses, destination)
            output = io.StringIO()
            with patch.dict(sys.modules, modules), patch("asyncio.sleep", new=AsyncMock()), contextlib.redirect_stdout(output):
                asyncio.run(login(destination, qr, 30))
            saved = json.loads(destination.read_text())
            self.assertEqual(saved["SESSDATA"], "RAW%2CSESSION")
            self.assertEqual(saved["buvid3"], "SDK_VISITOR3")
            self.assertEqual(saved["buvid4"], "SDK_VISITOR4")
            self.assertEqual(saved["DedeUserID"], "123")
            self.assertNotIn("sid", saved)
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(qr.stat().st_mode), 0o600)
            for secret in ["RAW,SESSION", "RAW%2CSESSION", "CSRF_SECRET", "PRIVATE_QR_KEY"]:
                self.assertNotIn(secret, output.getvalue())
            self.assertEqual([json.loads(line)["event"] for line in output.getvalue().splitlines()],
                             ["qr_ready", "awaiting_scan", "awaiting_confirmation", "poll_response", "authorized"])
            client.close.assert_awaited_once()

    def test_unknown_status_empty_session_and_expiry_never_overwrite_credentials(self):
        for code, cookies, error in [(86104, {"SESSDATA": "NOT_SUCCESS"}, VideoUnavailable),
                                     (False, {"SESSDATA": "NOT_SUCCESS"}, VideoUnavailable),
                                     (0, {"bili_jct": "NO_SESSION"}, VideoUnavailable),
                                     (86038, {}, TimeoutError)]:
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                destination, qr = Path(directory) / "credential.json", Path(directory) / "qr.png"
                destination.write_text("keep-old")
                responses = [self.response(generated=True), self.response(code, cookies)]
                modules, client = self.sdk(responses, destination)
                with patch.dict(sys.modules, modules), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(error):
                    asyncio.run(login(destination, qr, 30))
                self.assertEqual(destination.read_text(), "keep-old")
                client.close.assert_awaited_once()
