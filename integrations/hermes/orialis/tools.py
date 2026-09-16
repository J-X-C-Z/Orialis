"""Agent-facing discovery tools for the Orialis Hermes plugin."""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any, Dict
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen

logger = logging.getLogger(__name__)

CAPABILITIES_PATH = "/api/v1/capabilities"
DISCOVERY_TIMEOUT_SECONDS = 5
MAX_RESPONSE_BYTES = 64 * 1024

# This is the contract the plugin itself can fulfill. The server response is authoritative
# for server-side features and is merged with this local description by the tool.
PLUGIN_OPERATIONS = (
    {
        "name": "receive_message",
        "direction": "server_to_hermes",
        "protocol": "message.send",
        "description": "Receive an Orialis conversation message and pass supported image/document/text attachments to Hermes.",
    },
    {
        "name": "send_reply",
        "direction": "hermes_to_server",
        "protocol": "message.reply",
        "description": "Send the Hermes response and optional uploaded image/document attachments back to the matching conversation.",
    },
    {
        "name": "acknowledge_message",
        "direction": "hermes_to_server",
        "protocol": "message.ack",
        "description": "Acknowledge receipt of an Orialis message.",
    },
)

# These are advertised as contract metadata only.  Do not register them as
# callable tools until the corresponding server endpoints are implemented.
DOMAIN_CONTRACTS = {
    "task": {
        "resource": "/api/v1/tasks",
        "required": ["id", "title", "createdAt", "updatedAt", "version"],
        "calendar_visible": False,
    },
    "schedule": {
        "resource": "/api/v1/calendar-events (future /api/v1/schedules alias)",
        "required": ["id", "title", "startAt", "endAt", "createdAt", "updatedAt", "version"],
        "calendar_visible": True,
    },
    "conversation": {
        "resource": "not available in current server API",
        "required": ["id", "title", "createdAt", "updatedAt"],
        "callable": False,
    },
}

CAPABILITY_SCHEMA: Dict[str, Any] = {
    "name": "orialis_capabilities",
    "description": (
        "Read the capabilities currently advertised by the connected Orialis Server and the "
        "operations supported by the Orialis Hermes plugin. Use this before attempting an "
        "Orialis-specific action; this is read-only and accepts no arguments."
    ),
    "parameters": {
        "type": "object",
        "properties": {},
        "additionalProperties": False,
    },
}


def _http_capabilities_url(server_url: str) -> str:
    """Derive the versioned HTTP discovery URL from the configured Agent WS URL."""
    parsed = urlsplit(server_url.strip())
    if parsed.scheme not in {"ws", "wss", "http", "https"} or not parsed.netloc:
        raise ValueError("ORIALIS_SERVER_URL must be an absolute ws:// or wss:// URL")
    scheme = {"ws": "http", "wss": "https"}.get(parsed.scheme, parsed.scheme)
    return urlunsplit((scheme, parsed.netloc, CAPABILITIES_PATH, "", ""))


def _display_server_url(server_url: str) -> str | None:
    """Return the configured origin without query/fragment data that could contain secrets."""
    if not server_url:
        return None
    try:
        parsed = urlsplit(server_url)
        return urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    except ValueError:
        return "[invalid URL]"


def _fetch_server_capabilities(server_url: str) -> Dict[str, Any]:
    request = Request(
        _http_capabilities_url(server_url),
        headers={"Accept": "application/json", "User-Agent": "orialis-hermes-plugin/0.2.0"},
    )
    try:
        with urlopen(request, timeout=DISCOVERY_TIMEOUT_SECONDS) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
    except HTTPError as exc:
        return {"ok": False, "error": f"server returned HTTP {exc.code}"}
    except (URLError, TimeoutError, OSError) as exc:
        return {"ok": False, "error": f"server capability discovery failed: {exc}"}
    if len(body) > MAX_RESPONSE_BYTES:
        return {"ok": False, "error": "server capability response is too large"}
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return {"ok": False, "error": f"server returned invalid capability JSON: {exc}"}
    if not isinstance(payload, dict):
        return {"ok": False, "error": "server capability response must be a JSON object"}
    return {"ok": True, "payload": payload}


async def handle_capabilities(args: Dict[str, Any], **_kwargs: Any) -> str:
    """Return server capability discovery plus the plugin's local protocol operations."""
    del args
    server_url = os.getenv("ORIALIS_SERVER_URL", "").strip()
    server_result: Dict[str, Any]
    if not server_url:
        server_result = {"ok": False, "error": "ORIALIS_SERVER_URL is not configured"}
    else:
        try:
            server_result = await asyncio.to_thread(_fetch_server_capabilities, server_url)
        except ValueError as exc:
            server_result = {"ok": False, "error": str(exc)}

    result: Dict[str, Any] = {
        "ok": True,
        "plugin": {
            "name": "orialis-hermes",
            "version": "0.2.0",
            "operations": list(PLUGIN_OPERATIONS),
            "tools": ["orialis_capabilities"],
            "domain_contracts": DOMAIN_CONTRACTS,
        },
        "server": {
            "url": _display_server_url(server_url),
            "discovery": server_result,
        },
    }
    if server_result.get("ok"):
        payload = server_result.get("payload") or {}
        result["server"]["api_version"] = payload.get("api_version")
        result["server"]["capabilities"] = payload.get("capabilities", [])
    return json.dumps(result, ensure_ascii=False, separators=(",", ":"))


def register_tools(ctx: Any) -> None:
    """Register the read-only discovery tool without materializing the WS adapter."""
    ctx.register_tool(
        name="orialis_capabilities",
        toolset="orialis",
        schema=CAPABILITY_SCHEMA,
        handler=handle_capabilities,
        is_async=True,
        emoji="🔗",
    )
