from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


SCRIPT = Path(__file__).with_name("orialis_todo_digest.py")


class FakeOrialis:
    def __init__(self) -> None:
        self.tasks: list[dict] = []
        self.events: list[dict] = []
        self.fail = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_GET(self):
                if owner.fail:
                    self._json(503, {"error": "unavailable"})
                    return
                path = self.path.split("?", 1)[0]
                if path == "/api/v1/tasks":
                    self._json(200, {"items": owner.tasks, "hasMore": False, "nextCursor": None})
                    return
                if path == "/api/v1/schedules":
                    self._json(200, {"items": owner.events, "hasMore": False, "nextCursor": None})
                    return
                self._json(404, {"error": "not found"})

            def _json(self, status, payload):
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        host, port = self.server.server_address
        return f"http://{host}:{port}"

    def close(self) -> None:
        self.server.shutdown()
        self.server.server_close()


class DigestTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.fake = FakeOrialis()
        (self.home / ".env").write_text(
            f"ORIALIS_SERVER_URL={self.fake.url}\nORIALIS_DEVICE_TOKEN=test-secret\n",
            encoding="utf-8",
        )
        self.env = {
            **os.environ,
            "ORIALIS_DIGEST_HOME": str(self.home),
            "ORIALIS_DIGEST_NOW": "2026-10-25T19:00:00+08:00",
            "PYTHONIOENCODING": "utf-8",
        }

    def tearDown(self) -> None:
        self.fake.close()
        self.temp.cleanup()

    def run_script(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )

    def test_digest_matches_original_agenda_blocks(self) -> None:
        now = datetime(2026, 10, 25, 11, 0, tzinfo=timezone.utc)
        self.fake.tasks = [
            {"title": "Late task", "due": "2026-10-24", "dueTime": "20:00", "completed": False},
            {"title": "Today task", "due": "2026-10-25", "dueTime": "21:00", "completed": False},
            {"title": "Done task", "due": "2026-10-25", "completed": True},
            {"title": "Unscheduled", "due": None, "completed": False},
            {"title": "Tomorrow task", "due": "2026-10-26", "dueTime": "08:00", "completed": False},
        ]
        self.fake.events = [
            {
                "title": "Meeting",
                "startAt": now.isoformat(),
                "endAt": "2026-10-25T12:00:00Z",
                "allDay": False,
            },
            {
                "title": "Morning class",
                "startAt": "2026-10-25T23:00:00Z",
                "endAt": "2026-10-26T00:00:00Z",
                "allDay": False,
            },
        ]
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("test-secret", result.stdout + result.stderr)
        self.assertIn("日程清单 10-25", result.stdout)
        self.assertIn("今天：19:00 Meeting；21:00 Today task", result.stdout)
        self.assertIn("明天：07:00 Morning class；08:00 Tomorrow task", result.stdout)
        self.assertIn("逾期：20:00 Late task（2026-10-24）", result.stdout)
        self.assertNotIn("Done task", result.stdout)
        self.assertNotIn("Unscheduled", result.stdout)

    def test_digest_uses_original_empty_blocks(self) -> None:
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("今天：无", result.stdout)
        self.assertIn("明天：无", result.stdout)
        self.assertIn("逾期：无", result.stdout)

    def test_api_failure_exits_nonzero(self) -> None:
        self.fake.fail = True
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("HTTP 503", result.stderr)

    def test_explicit_profile_home_overrides_environment_default(self) -> None:
        alternate = Path(tempfile.mkdtemp())
        try:
            (alternate / ".env").write_text(
                f"ORIALIS_SERVER_URL={self.fake.url}\nORIALIS_DEVICE_TOKEN=test-secret\n",
                encoding="utf-8",
            )
            result = self.run_script("--profile-home", str(alternate))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("日程清单", result.stdout)
        finally:
            import shutil
            shutil.rmtree(alternate)


if __name__ == "__main__":
    unittest.main()
