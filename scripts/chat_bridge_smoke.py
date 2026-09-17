#!/usr/bin/env python3
"""Verify the local Orialis mobile -> Hermes -> mobile chat bridge.

Run against a development server with ORIALIS_DEV_DEVICE_AUTH=true. The fake
Hermes peer uses the same Agent Gateway frames as the real plugin, so no model
or external service is needed.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
import urllib.request
import uuid

import websockets


def post_message(http_url: str, device_id: str, conversation_id: str, message_id: str) -> dict:
    body = json.dumps({"id": message_id, "content": "请回复 ORIALIS_BRIDGE_OK"}).encode()
    request = urllib.request.Request(
        f"{http_url.rstrip('/')}/api/v1/conversations/{conversation_id}/messages",
        data=body,
        headers={
            "X-Orialis-Device-Id": device_id,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode())


def create_conversation(http_url: str, device_id: str, conversation_id: str) -> dict:
    body = json.dumps({"id": conversation_id, "title": "Orialis bridge smoke"}).encode()
    request = urllib.request.Request(
        f"{http_url.rstrip('/')}/api/v1/conversations",
        data=body,
        headers={
            "X-Orialis-Device-Id": device_id,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode())


def list_messages(http_url: str, device_id: str, conversation_id: str) -> list[dict]:
    request = urllib.request.Request(
        f"{http_url.rstrip('/')}/api/v1/conversations/{conversation_id}/messages",
        headers={"X-Orialis-Device-Id": device_id},
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return json.loads(response.read().decode())


async def run(args: argparse.Namespace) -> None:
    device_id = f"smoke-device-{uuid.uuid4().hex[:8]}"
    conversation_id = f"smoke-conversation-{uuid.uuid4().hex[:8]}"
    message_id = f"smoke-message-{uuid.uuid4().hex[:8]}"

    async with (
        websockets.connect(args.agent_ws_url) as agent,
        websockets.connect(
            args.mobile_ws_url,
            additional_headers={"X-Orialis-Device-Id": device_id},
        ) as mobile,
    ):
        await asyncio.to_thread(
            create_conversation, args.http_url, device_id, conversation_id
        )
        await agent.send(json.dumps({
            "version": 1,
            "type": "hello",
            "device_id": "JXCZ_SMOKE_Hermes",
            "client": "orialis-chat-bridge-smoke",
            "plugin_version": "0.1.0",
            "platform": "test",
        }))
        assert json.loads(await agent.recv())["type"] == "hello_ack"

        await mobile.send(json.dumps({
            "version": 1,
            "type": "hello",
            "device_id": device_id,
            "platform": "android",
            "client": "orialis_mobile",
            "payload": {},
        }))
        assert json.loads(await mobile.recv())["type"] == "hello.ack"

        await asyncio.to_thread(
            post_message, args.http_url, device_id, conversation_id, message_id
        )
        request = json.loads(await agent.recv())
        assert request["type"] == "message.send", request
        assert request["message_id"] == message_id, request
        await agent.send(json.dumps({
            "version": 1,
            "type": "message.ack",
            "message_id": message_id,
            "status": "received",
        }))
        await agent.send(json.dumps({
            "version": 1,
            "type": "message.reply",
            "message_id": f"reply-{uuid.uuid4().hex[:8]}",
            "reply_to": message_id,
            "conversation_id": conversation_id,
            "content": "ORIALIS_BRIDGE_OK",
        }))
        assert json.loads(await agent.recv())["type"] == "message.ack"

        deadline = time.monotonic() + 10
        messages: list[dict] = []
        while time.monotonic() < deadline:
            messages = await asyncio.to_thread(
                list_messages, args.http_url, device_id, conversation_id
            )
            if any(item.get("role") == "assistant" for item in messages):
                break
            await asyncio.sleep(0.1)
        assert any(
            item.get("role") == "assistant" and item.get("content") == "ORIALIS_BRIDGE_OK"
            for item in messages
        ), messages

        realtime_types = set()
        while True:
            try:
                event = json.loads(await asyncio.wait_for(mobile.recv(), timeout=0.2))
                realtime_types.add(event.get("type"))
            except asyncio.TimeoutError:
                break
        assert "message" in realtime_types, realtime_types
        assert "sync.change_hint" in realtime_types, realtime_types

    print(json.dumps({"ok": True, "assistant": "ORIALIS_BRIDGE_OK"}))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--http-url", default="http://127.0.0.1:18443")
    parser.add_argument("--agent-ws-url", default="ws://127.0.0.1:18443/api/v1/agent/ws")
    parser.add_argument("--mobile-ws-url", default="ws://127.0.0.1:18443/api/v1/ws")
    asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    main()
