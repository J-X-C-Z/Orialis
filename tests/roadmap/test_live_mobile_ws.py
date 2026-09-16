from __future__ import annotations

import asyncio
import json
import unittest

from .support import LiveServerMixin, session_headers

try:
    import websockets
except ImportError:  # pragma: no cover - intentionally visible as a test skip
    websockets = None


async def receive_json(socket, timeout: float = 5.0) -> dict:
    return json.loads(await asyncio.wait_for(socket.recv(), timeout=timeout))


class LiveMobileRealtimeTests(LiveServerMixin, unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        super().setUpClass()
        if websockets is None:
            raise unittest.SkipTest("mobile WebSocket tests require the optional websockets package")

    def test_session_hello_ping_and_reconnect_contract(self) -> None:
        asyncio.run(self._session_hello_ping_and_reconnect_contract())

    async def _session_hello_ping_and_reconnect_contract(self) -> None:
        token, _ = self.shared_session()
        headers = session_headers(token)
        url = self._ws_url()
        first_connection_id = None
        for index in range(2):
            async with websockets.connect(url, additional_headers=headers) as socket:
                await socket.send(json.dumps({
                    "version": 1,
                    "type": "hello",
                    "request_id": f"roadmap-hello-{index}",
                    "payload": {"client": "roadmap-black-box", "platform": "test"},
                }))
                hello_ack = await receive_json(socket)
                self.assertEqual(hello_ack["type"], "hello.ack")
                self.assertEqual(hello_ack["request_id"], f"roadmap-hello-{index}")
                self.assertTrue(hello_ack["payload"].get("connection_id"))
                if first_connection_id is None:
                    first_connection_id = hello_ack["payload"]["connection_id"]
                else:
                    self.assertNotEqual(hello_ack["payload"]["connection_id"], first_connection_id)

                await socket.send(json.dumps({
                    "version": 1,
                    "type": "ping",
                    "request_id": f"roadmap-ping-{index}",
                    "payload": {},
                }))
                pong = await receive_json(socket)
                self.assertEqual(pong["type"], "pong")
                self.assertEqual(pong["request_id"], f"roadmap-ping-{index}")

    def _ws_url(self) -> str:
        from urllib.parse import urlsplit, urlunsplit
        from .support import base_url

        parsed = urlsplit(base_url())
        scheme = "wss" if parsed.scheme == "https" else "ws"
        return urlunsplit((scheme, parsed.netloc, "/api/v1/ws", "", ""))
