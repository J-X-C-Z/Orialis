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
from urllib.parse import parse_qs, urlsplit


SCRIPT = Path(__file__).with_name("orialis_inbox_watch.py")


class FakeOrialis:
    def __init__(self) -> None:
        self.messages: list[dict] = []
        self.fail_messages = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                return

            def do_GET(self):
                parsed = urlsplit(self.path)
                if parsed.path == "/api/v1/conversations":
                    self._json(
                        200,
                        [
                            {
                                "id": "conversation-1",
                                "title": "Test conversation",
                                "createdAt": "2026-10-25T00:00:00Z",
                            }
                        ],
                    )
                    return
                if parsed.path == "/api/v1/conversations/conversation-1/messages":
                    if owner.fail_messages:
                        self._json(503, {"error": "unavailable"})
                        return
                    query = parse_qs(parsed.query)
                    limit = int(query.get("limit", ["500"])[0])
                    after = query.get("after", [None])[0]
                    start = 0
                    if after:
                        start = int(after)
                    batch = owner.messages[start : start + limit]
                    has_more = start + limit < len(owner.messages)
                    self._json(
                        200,
                        {
                            "items": batch,
                            "hasMore": has_more,
                            "nextCursor": str(start + limit) if has_more else None,
                        },
                    )
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

    def add_message(self, role: str, text: str, *, message_id: str, created_at: str) -> None:
        self.messages.append(
            {
                "id": message_id,
                "conversationId": "conversation-1",
                "role": role,
                "content": text,
                "createdAt": created_at,
                "attachments": [],
            }
        )


class InboxWatchTest(unittest.TestCase):
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
            "ORIALIS_INBOX_HOME": str(self.home),
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

    def last_json(self, result: subprocess.CompletedProcess[str]) -> dict:
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("test-secret", result.stdout + result.stderr)
        return json.loads([line for line in result.stdout.splitlines() if line.strip()][-1])

    def test_initializes_then_emits_only_new_user_messages_and_acks(self) -> None:
        initial = self.last_json(self.run_script())
        self.assertEqual(initial["status"], "initialized")
        self.assertFalse(initial["wakeAgent"])

        self.fake.add_message(
            "user",
            "Please remind me tomorrow at 09:00",
            message_id="m1",
            created_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        self.fake.add_message(
            "assistant",
            "Done",
            message_id="m2",
            created_at=datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        )
        scanned = self.last_json(self.run_script())
        self.assertEqual(scanned["status"], "new_messages")
        self.assertEqual(scanned["messageCount"], 1)
        self.assertEqual(scanned["messages"][0]["id"], "m1")
        self.assertTrue(scanned["wakeAgent"])

        duplicate_scan = self.last_json(self.run_script())
        self.assertEqual(duplicate_scan["status"], "pending_messages")
        self.assertEqual(duplicate_scan["batchId"], scanned["batchId"])

        acked = self.last_json(self.run_script("ack", "--batch", scanned["batchId"]))
        self.assertTrue(acked["acked"])

        quiet = self.last_json(self.run_script())
        self.assertEqual(quiet["status"], "no_new_messages")
        self.assertFalse(quiet["wakeAgent"])

    def test_new_messages_wait_behind_pending_batch(self) -> None:
        self.last_json(self.run_script())
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        self.fake.add_message("user", "first", message_id="m1", created_at=now)
        first = self.last_json(self.run_script())
        self.fake.add_message("user", "second", message_id="m2", created_at=now)
        pending = self.last_json(self.run_script())
        self.assertEqual([item["id"] for item in pending["messages"]], ["m1"])
        self.last_json(self.run_script("ack", "--batch", first["batchId"]))
        second = self.last_json(self.run_script())
        self.assertEqual([item["id"] for item in second["messages"]], ["m2"])

    def test_api_failure_does_not_advance_or_create_pending(self) -> None:
        self.last_json(self.run_script())
        self.fake.fail_messages = True
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        status = self.last_json(self.run_script("status"))
        self.assertIsNone(status["pendingBatchId"])

    def test_explicit_profile_home_overrides_environment_default(self) -> None:
        alternate = Path(tempfile.mkdtemp())
        try:
            result = self.run_script("--profile-home", str(alternate))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "initialized")
            self.assertTrue((alternate / "state" / "orialis-inbox-watch.json").is_file())
        finally:
            import shutil
            shutil.rmtree(alternate)


if __name__ == "__main__":
    unittest.main()
