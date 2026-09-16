"""Strict, dependency-light Orialis Agent Gateway protocol helpers."""

from __future__ import annotations

import json
from typing import Any, Mapping, Optional

PROTOCOL_VERSION = 1
KNOWN_TYPES = frozenset(
    {
        "hello", "hello_ack", "ping", "pong", "message.send", "message.reply", "message.ack", "error"
    }
)


class ProtocolError(ValueError):
    """A malformed or unsupported Agent Gateway frame."""

    def __init__(self, message: str, *, code: str = "INVALID_MESSAGE") -> None:
        super().__init__(message)
        self.code = code


def _object(raw: Any) -> dict[str, Any]:
    if isinstance(raw, bytes):
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ProtocolError("payload is not valid UTF-8") from exc
    if isinstance(raw, str):
        try:
            raw = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise ProtocolError("payload is not valid JSON") from exc
    if not isinstance(raw, Mapping):
        raise ProtocolError("message must be a JSON object")
    return dict(raw)


def _required_text(message: Mapping[str, Any], field: str) -> str:
    value = message.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError(f"missing {field}")
    return value


def parse_message(raw: Any) -> dict[str, Any]:
    """Parse one frame, returning a normalized dictionary without raising on unknown type."""
    message = _object(raw)
    version = message.get("version")
    if not isinstance(version, int) or isinstance(version, bool):
        raise ProtocolError("missing or invalid version")
    if version != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol version {version}", code="UNSUPPORTED_VERSION")
    message_type = message.get("type")
    if not isinstance(message_type, str) or not message_type.strip():
        raise ProtocolError("missing type")
    if message_type not in KNOWN_TYPES:
        raise ProtocolError(f"unknown message type {message_type}", code="UNKNOWN_TYPE")

    if message_type == "hello":
        for field in ("device_id", "client", "plugin_version", "platform"):
            _required_text(message, field)
    elif message_type == "message.send":
        for field in ("message_id", "conversation_id", "content"):
            _required_text(message, field)
    elif message_type == "message.reply":
        for field in ("message_id", "reply_to", "conversation_id", "content"):
            _required_text(message, field)
    elif message_type == "message.ack":
        for field in ("message_id", "status"):
            _required_text(message, field)
    elif message_type == "error":
        for field in ("code", "message"):
            _required_text(message, field)
        if "reply_to" in message and message["reply_to"] is not None:
            _required_text(message, "reply_to")
    return message


def encode(message: Mapping[str, Any]) -> str:
    """Validate and encode a protocol frame as UTF-8 JSON text."""
    parsed = parse_message(message)
    return json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))


def hello(device_id: str, plugin_version: str = "0.1.0", platform: str = "macos") -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "hello",
        "device_id": device_id,
        "client": "orialis-hermes-plugin",
        "plugin_version": plugin_version,
        "platform": platform,
    }


def hello_ack() -> dict[str, Any]:
    return {"version": PROTOCOL_VERSION, "type": "hello_ack"}


def ping() -> dict[str, Any]:
    return {"version": PROTOCOL_VERSION, "type": "ping"}


def pong() -> dict[str, Any]:
    return {"version": PROTOCOL_VERSION, "type": "pong"}


def ack(message_id: str, status: str = "received") -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "message.ack",
        "message_id": message_id,
        "status": status,
    }


def reply(
    *, message_id: str, reply_to: str, conversation_id: str, content: str
) -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION,
        "type": "message.reply",
        "message_id": message_id,
        "reply_to": reply_to,
        "conversation_id": conversation_id,
        "content": content,
    }


def error(code: str, message: str, reply_to: Optional[str] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "version": PROTOCOL_VERSION,
        "type": "error",
        "code": code,
        "message": message,
    }
    if reply_to:
        payload["reply_to"] = reply_to
    return payload
