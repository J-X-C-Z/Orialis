import asyncio
import copy
import os
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

from gateway.config import Platform
from ..adapter import OrialisAdapter
from ..attachment_cache import AttachmentCache, RETENTION_SECONDS


class AttachmentCacheTests(unittest.TestCase):
    def setUp(self):
        Platform._add_pseudo_member("orialis")
        self.home = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {"HERMES_HOME": self.home.name})
        self.env.start()
        self.addCleanup(self.home.cleanup)
        self.addCleanup(self.env.stop)

    def test_real_http_files_survive_completion_disconnect_restart_and_reuse(self):
        class Handler(BaseHTTPRequestHandler):
            requests = 0

            def do_GET(self):
                Handler.requests += 1
                data = b"first" if self.path == "/one" else b"second"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        url = f"http://127.0.0.1:{server.server_port}"
        config = SimpleNamespace(extra={"server_url": url, "device_id": "JXCZ_TEST_Hermes"})
        message = {"message_id": "m", "conversation_id": "c", "content": "read",
                   "attachments": [
                       {"id": "a", "name": "notes.txt", "mime_type": "text/plain", "download_url": url + "/one"},
                       {"id": "b", "name": "notes.txt", "mime_type": "text/plain", "download_url": url + "/two"},
                   ]}
        events = []

        async def noop(*args, **kwargs):
            pass

        async def handle(event):
            event._gateway_accepted = True
            events.append(event)

        def make_adapter():
            adapter = OrialisAdapter(config)
            adapter._send_wire = noop
            adapter.send_agent_state = noop
            adapter.handle_message = handle
            return adapter

        async def scenario():
            first = make_adapter()
            await first._dispatch_message(copy.deepcopy(message))
            original = events[-1]
            paths = [Path(p) for p in original.media_urls]
            self.assertNotEqual(paths[0], paths[1])
            self.assertEqual([p.read_bytes() for p in paths], [b"first", b"second"])
            # A socket disconnect while the model still processes must retain files.
            await first.disconnect()
            self.assertEqual([p.read_bytes() for p in paths], [b"first", b"second"])
            await first.on_processing_complete(original, SimpleNamespace(value="success"))
            self.assertEqual([p.read_bytes() for p in paths], [b"first", b"second"])
            # A later text-only turn can read the same history paths.
            await first._dispatch_message({"message_id": "followup", "conversation_id": "c", "content": "continue"})
            self.assertEqual([p.read_bytes() for p in paths], [b"first", b"second"])
            restarted = make_adapter()
            await restarted._dispatch_message(copy.deepcopy(message))
            self.assertEqual(events[-1].media_urls, original.media_urls)
            self.assertEqual(Handler.requests, 2)

        asyncio.run(scenario())

    def test_expiry_skips_active_and_completion_refreshes_retention(self):
        cache = AttachmentCache("https://one", "device", "token")
        old = cache.acquire("c", "old")
        cache.release("old")
        active = cache.acquire("c", "active")
        fresh = cache.acquire("c", "fresh")
        cache.release("fresh")
        expired = time.time() - RETENTION_SECONDS - 60
        os.utime(old, (expired, expired))
        os.utime(active, (expired, expired))
        cache.prune()
        self.assertFalse(old.exists())
        self.assertTrue(active.exists())
        self.assertTrue(fresh.exists())
        cache.release("active")
        cache.prune()
        self.assertTrue(active.exists())

    def test_scope_isolates_server_device_and_credentials(self):
        roots = [AttachmentCache(*args).root for args in [
            ("https://one", "d1", "t1"), ("https://two", "d1", "t1"),
            ("https://one", "d2", "t1"), ("https://one", "d1", "t2"),
        ]]
        self.assertEqual(len(set(roots)), 4)

    def test_failed_download_removes_partial_and_can_retry(self):
        from .. import adapter as module
        adapter = OrialisAdapter(SimpleNamespace(extra={
            "server_url": "https://orialis.test", "device_id": "JXCZ_TEST_Hermes"}))
        events, frames = [], []

        async def send(frame):
            frames.append(frame)

        async def handle(event):
            events.append(event)

        adapter._send_wire = send
        adapter.handle_message = handle
        message = {"message_id": "bad", "conversation_id": "c", "content": "",
                   "attachments": [{"id": "a", "name": "a.txt", "mime_type": "text/plain",
                                    "download_url": "https://orialis.test/a"}]}

        def failed(*args):
            args[2].write_bytes(b"incomplete")
            raise OSError("broken stream")

        def success(*args):
            args[2].write_bytes(b"complete")
            return "text/plain"

        with patch.object(module, "_download_attachment", failed):
            asyncio.run(adapter._dispatch_message(message))
        self.assertEqual(frames[-1]["code"], "ATTACHMENT_UNAVAILABLE")
        self.assertFalse(list(adapter._attachment_cache.root.rglob("*.part")))
        self.assertFalse(events)
        with patch.object(module, "_download_attachment", success):
            asyncio.run(adapter._dispatch_message(message))
        self.assertEqual(Path(events[0].media_urls[0]).read_bytes(), b"complete")
