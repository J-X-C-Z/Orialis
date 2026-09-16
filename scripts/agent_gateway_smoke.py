#!/usr/bin/env python3
"""Exercise the Orialis Agent Gateway with a deterministic fake Hermes peer.

This verifies the M1–M5 Server-side path without invoking a model. A real Hermes
run uses the same frames through integrations/hermes/orialis.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import urllib.request

import websockets


def trigger_message(http_url: str, content: str, conversation_id: str) -> dict:
    payload = json.dumps({
        "conversation_id": conversation_id,
        "content": content,
        "message_id": "smoke_request_001",
    }).encode("utf-8")
    request = urllib.request.Request(
        f"{http_url.rstrip('/')}/api/v1/agent/debug/message",
        data=payload,
        headers={"content-type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=70) as response:
        return json.loads(response.read().decode("utf-8"))


async def run(args: argparse.Namespace) -> None:
    headers = {}
    if args.device_token:
        headers["Authorization"] = f"Bearer {args.device_token}"
    async with websockets.connect(args.ws_url, additional_headers=headers) as socket:
        await socket.send(json.dumps({
            "version": 1,
            "type": "hello",
            "device_id": "JXCZ_SMOKE_Hermes",
            "client": "orialis-gateway-smoke",
            "plugin_version": "0.1.0",
            "platform": "test",
        }))
        hello_ack = json.loads(await socket.recv())
        assert hello_ack["type"] == "hello_ack", hello_ack

        await socket.send(json.dumps({"version": 1, "type": "ping"}))
        pong = json.loads(await socket.recv())
        assert pong["type"] == "pong", pong

        reply_task = asyncio.create_task(asyncio.to_thread(
            trigger_message, args.http_url, args.content, args.conversation_id
        ))
        request = json.loads(await socket.recv())
        assert request["type"] == "message.send", request
        assert request["content"] == args.content, request
        await socket.send(json.dumps({
            "version": 1,
            "type": "message.ack",
            "message_id": request["message_id"],
            "status": "received",
        }))
        await socket.send(json.dumps({
            "version": 1,
            "type": "message.reply",
            "message_id": "smoke_reply_001",
            "reply_to": request["message_id"],
            "conversation_id": request["conversation_id"],
            "content": "ORIALIS_OK",
        }, ensure_ascii=False))
        server_ack = json.loads(await socket.recv())
        assert server_ack["type"] == "message.ack", server_ack
        assert server_ack["message_id"] == "smoke_reply_001", server_ack
        response = await reply_task
        assert response["type"] == "message.reply", response
        assert "ORIALIS_OK" in response["content"], response
        print(json.dumps(response, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--http-url", default="http://127.0.0.1:18443")
    parser.add_argument("--ws-url", default="ws://127.0.0.1:18443/api/v1/agent/ws")
    parser.add_argument("--conversation-id", default="smoke-conversation")
    parser.add_argument("--content", default="请回复 ORIALIS_OK")
    parser.add_argument(
        "--device-token",
        default=os.environ.get("ORIALIS_DEVICE_TOKEN"),
        help="Bearer token for a production Agent Gateway; may also come from ORIALIS_DEVICE_TOKEN",
    )
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
