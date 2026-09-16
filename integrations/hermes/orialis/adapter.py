"""Hermes platform adapter for the Orialis Server Agent Gateway."""

from __future__ import annotations

import asyncio
import hashlib
import mimetypes
import logging
import os
import re
import platform as host_platform
import tempfile
import time
import uuid
from collections import OrderedDict
from pathlib import Path
from typing import Any, Dict, Mapping, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import Request, urlopen

try:
    import websockets
    from websockets.exceptions import ConnectionClosed
except ImportError:  # pragma: no cover - exercised in a Hermes install without websockets
    websockets = None  # type: ignore[assignment]
    ConnectionClosed = Exception  # type: ignore[misc,assignment]

from gateway.config import Platform
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent, MessageType
from .config import OrialisConfig, env_enablement, validate
from .conversation import chat_id_for_conversation, conversation_id_for_chat_id
from . import protocol

logger = logging.getLogger(__name__)

PLUGIN_VERSION = "1.0.0"
ACK_TIMEOUT_SECONDS = 10.0
RECONNECT_INITIAL_DELAY_SECONDS = 1.0
RECONNECT_MAX_DELAY_SECONDS = 30.0
SEEN_MESSAGE_CACHE = 4096
ATTACHMENT_MAX_BYTES = 20 * 1024 * 1024
ATTACHMENT_DOWNLOAD_TIMEOUT_SECONDS = 15
ATTACHMENT_UPLOAD_TIMEOUT_SECONDS = 30
_SAFE_NAME = re.compile(r"[^\w. ()\-\u4e00-\u9fff]+", re.UNICODE)
_EXCLUDED_MIME_PREFIXES = ("audio/", "video/")


def _safe_filename(name: str, fallback: str = "attachment") -> str:
    """Keep only a display name; never allow a path component or special dot name."""
    clean = Path(str(name or "")).name.replace("\x00", "")
    clean = _SAFE_NAME.sub("_", clean).strip(" .")[:180]
    return clean if clean and clean not in {".", ".."} else fallback


def _allowed_mime(mime: str) -> bool:
    mime = (mime or "").split(";", 1)[0].strip().lower()
    if not mime or mime.startswith(_EXCLUDED_MIME_PREFIXES):
        return False
    return mime.startswith("image/") or mime.startswith("text/") or mime in {
        "application/pdf", "application/json", "application/xml", "application/octet-stream",
    }


def _http_origin(url: str) -> tuple[str, str, int | None]:
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https", "ws", "wss"} or not parsed.netloc:
        raise ValueError("attachment URL must be an absolute HTTP(S) URL")
    scheme = {"ws": "http", "wss": "https"}.get(parsed.scheme, parsed.scheme)
    return scheme, parsed.hostname or "", parsed.port


def _same_server(url: str, server_url: str) -> bool:
    a = _http_origin(url)
    b = _http_origin(server_url)
    return a == b


def _download_attachment(
    item: Dict[str, Any], server_url: str, destination: Path,
    token: str | None = None, device_id: str | None = None,
) -> str:
    item = protocol._normalize_attachment(item)
    url = item["download_url"]
    if not _same_server(url, server_url):
        raise ValueError("attachment download URL is outside the configured Orialis Server")
    declared = item["mime_type"].lower().split(";", 1)[0].strip()
    if not _allowed_mime(declared):
        raise ValueError(f"unsupported attachment MIME type {declared}")
    request = Request(url, headers={"Accept": declared, "User-Agent": "orialis-hermes-plugin/0.2.0"})
    token = (token or os.getenv("ORIALIS_DEVICE_TOKEN", "")).strip()
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    if device_id:
        request.add_header("X-Orialis-Device-Id", device_id)
    with urlopen(request, timeout=ATTACHMENT_DOWNLOAD_TIMEOUT_SECONDS) as response:
        response_mime = response.headers.get_content_type().lower()
        if response_mime not in {"application/octet-stream", declared} and not (
            declared.endswith("/*") and response_mime.startswith(declared[:-1])
        ):
            raise ValueError("downloaded attachment MIME does not match metadata")
        length = response.headers.get("Content-Length")
        if length and int(length) > ATTACHMENT_MAX_BYTES:
            raise ValueError("attachment exceeds 20 MB")
        total = 0
        with destination.open("wb") as output:
            while True:
                chunk = response.read(min(64 * 1024, ATTACHMENT_MAX_BYTES - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                if total > ATTACHMENT_MAX_BYTES:
                    raise ValueError("attachment exceeds 20 MB")
                output.write(chunk)
    if not total:
        raise ValueError("attachment is empty")
    return declared


def _upload_attachment(
    path: str, server_url: str, conversation_id: str,
    token: str | None = None, device_id: str | None = None,
) -> Dict[str, Any]:
    file_path = Path(path)
    size = file_path.stat().st_size
    if size <= 0 or size > ATTACHMENT_MAX_BYTES:
        raise ValueError("attachment must be between 1 byte and 20 MB")
    mime = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    if not _allowed_mime(mime):
        raise ValueError(f"unsupported attachment MIME type {mime}")
    boundary = f"orialis-{uuid.uuid4().hex}"
    body = bytearray()
    def add(value: bytes) -> None: body.extend(value)
    add(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{_safe_filename(file_path.name)}\"\r\nContent-Type: {mime}\r\n\r\n".encode())
    add(file_path.read_bytes())
    add(f"\r\n--{boundary}--\r\n".encode())
    parsed = urlsplit(server_url)
    scheme = {"ws": "http", "wss": "https"}.get(parsed.scheme, parsed.scheme)
    endpoint = urlunsplit((scheme, parsed.netloc, f"/api/v1/conversations/{quote(conversation_id, safe='')}/attachments", "", ""))
    idempotency_key = hashlib.sha256(
        f"{conversation_id}:{file_path.resolve()}:{size}:{file_path.stat().st_mtime_ns}".encode()
    ).hexdigest()
    request = Request(endpoint, data=bytes(body), method="POST", headers={
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Accept": "application/json", "Idempotency-Key": idempotency_key,
        "User-Agent": "orialis-hermes-plugin/0.2.0",
    })
    token = (token or os.getenv("ORIALIS_DEVICE_TOKEN", "")).strip()
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    if device_id:
        request.add_header("X-Orialis-Device-Id", device_id)
    with urlopen(request, timeout=ATTACHMENT_UPLOAD_TIMEOUT_SECONDS) as response:
        import json
        payload = json.loads(response.read(128 * 1024).decode("utf-8"))
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list) or not items or not isinstance(items[0], dict):
        raise ValueError("Orialis Server returned no attachment metadata")
    return protocol._normalize_attachment(items[0])


def check_requirements() -> bool:
    return websockets is not None


def _platform_name() -> str:
    value = host_platform.system().lower()
    return {"darwin": "macos", "windows": "windows"}.get(value, value)


class OrialisAdapter(BasePlatformAdapter):
    """Thin WebSocket bridge; Hermes remains responsible for agent execution."""

    supports_code_blocks = False
    interactive_resume = False
    SUPPORTS_NATIVE_STREAMING = True

    def __init__(self, config: Any):
        super().__init__(config=config, platform=Platform("orialis"))
        self._orialis = OrialisConfig.from_platform_config(config)
        self._ws = None
        self._reader_task: Optional[asyncio.Task] = None
        self._send_lock = asyncio.Lock()
        self._connect_lock = asyncio.Lock()
        self._reconnect_task: Optional[asyncio.Task] = None
        self._manual_disconnect = False
        self._connection_state = "disconnected"
        self._ack_waiters: Dict[str, asyncio.Future] = {}
        self._seen_message_ids: set[str] = set()
        self._seen_message_order: list[str] = []
        self._seen_delivery_ids: set[str] = set()
        self._seen_delivery_order: list[str] = []
        self._reply_anchors: Dict[str, str] = {}
        self._command_anchors: Dict[str, str] = {}
        self._server_capabilities: set[str] = set()
        self._negotiated = False
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._request_waiters: Dict[str, asyncio.Future] = {}
        self._pending_interactions: Dict[str, Dict[str, Any]] = {}
        self._resolved_interactions: "OrderedDict[str, float]" = OrderedDict()
        self._active_streams: Dict[str, Dict[str, Any]] = {}
        self._stream_context: Dict[str, Any] = {}
        self._scheduled_wire_tasks: set[asyncio.Task] = set()
        self._inbound_tempdirs: Dict[str, tempfile.TemporaryDirectory] = {}
        self._session_id = f"session_{uuid.uuid4().hex[:16]}"
        self._event_seq = 0
        self._capability_probe_task: Optional[asyncio.Task] = None

    @property
    def connection_state(self) -> str:
        return self._connection_state

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        self._manual_disconnect = False
        async with self._connect_lock:
            if self._ws is not None and self._running:
                return True
            if websockets is None:
                logger.error("[%s] websockets package is not installed", self.name)
                self._connection_state = "failed"
                return False
            if not self._orialis.server_url or not self._orialis.device_id:
                logger.error("[%s] ORIALIS_SERVER_URL and ORIALIS_DEVICE_ID are required", self.name)
                self._connection_state = "failed"
                return False
            self._connection_state = "reconnecting" if is_reconnect else "connecting"
            self._loop = asyncio.get_running_loop()
            self._server_capabilities = set()
            self._negotiated = False
            headers = {}
            if self._orialis.device_token:
                headers["Authorization"] = f"Bearer {self._orialis.device_token}"
            try:
                await self._close_socket()
                kwargs: Dict[str, Any] = {"ping_interval": 30, "ping_timeout": 60}
                if headers:
                    kwargs["additional_headers"] = headers
                self._ws = await websockets.connect(self._orialis.server_url, **kwargs)
                await self._send_wire(protocol.hello(
                    self._orialis.device_id, plugin_version=PLUGIN_VERSION, platform=_platform_name(),
                    capabilities=sorted(protocol.SUPPORTED_CAPABILITIES),
                ))
                raw_ack = await asyncio.wait_for(self._ws.recv(), timeout=15)
                ack = protocol.parse_message(raw_ack)
                if not isinstance(ack, dict) or ack.get("type") != "hello_ack":
                    raise protocol.ProtocolError("expected hello_ack during handshake")
                # An omitted capabilities field is the v0.2 server contract. Keep
                # advanced features disabled in that case so a new frame can never
                # be sent to a peer that would reject it.
                self._server_capabilities = protocol.capabilities_from_ack(ack)
                self._negotiated = bool(ack.get("capabilities") or ack.get("features"))
                self._mark_connected()
                self._connection_state = "connected"
                self._reader_task = asyncio.create_task(self._receive_loop(), name="orialis-agent-reader")
                self._wire_plugin_handlers(None)
                # Keep the first post-hello frame available for the v0.2
                # message ACK path. A short idle probe upgrades peers that
                # implement the event-v1 capabilities handshake.
                self._capability_probe_task = asyncio.create_task(
                    self._send_capabilities_probe(), name="orialis-capability-probe"
                )
                logger.info("[%s] connected to Orialis Server", self.name)
                return True
            except Exception as exc:
                self._connection_state = "failed"
                logger.error("[%s] failed to connect to Orialis Server: %s", self.name, exc)
                await self._close_socket()
                return False

    async def disconnect(self) -> None:
        self._manual_disconnect = True
        self._connection_state = "stopped"
        reconnect_task, self._reconnect_task = self._reconnect_task, None
        if reconnect_task and reconnect_task is not asyncio.current_task():
            reconnect_task.cancel()
            try:
                await reconnect_task
            except asyncio.CancelledError:
                pass
        self._mark_disconnected()
        probe, self._capability_probe_task = self._capability_probe_task, None
        if probe and probe is not asyncio.current_task():
            probe.cancel()
            try:
                await probe
            except asyncio.CancelledError:
                pass
        task, self._reader_task = self._reader_task, None
        if task and task is not asyncio.current_task():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        await self._close_socket()
        self._fail_ack_waiters(ConnectionError("Orialis Server connection closed"))
        self._fail_request_waiters(ConnectionError("Orialis Server connection closed"))
        for message_id in list(self._inbound_tempdirs):
            self._release_inbound_tempdir(message_id)
        logger.info("[%s] disconnected from Orialis Server", self.name)

    def _schedule_reconnect(self) -> None:
        if self._manual_disconnect or (
            self._reconnect_task is not None and not self._reconnect_task.done()
        ):
            return
        self._reconnect_task = asyncio.create_task(
            self._reconnect_loop(), name="orialis-agent-reconnect"
        )

    async def _reconnect_loop(self) -> None:
        delay = RECONNECT_INITIAL_DELAY_SECONDS
        self._connection_state = "reconnecting"
        while not self._manual_disconnect:
            logger.info("[%s] reconnecting to Orialis Server in %.1fs", self.name, delay)
            await asyncio.sleep(delay)
            if await self.connect(is_reconnect=True):
                logger.info("[%s] Orialis Server connection restored", self.name)
                return
            delay = min(delay * 2, RECONNECT_MAX_DELAY_SECONDS)

    def _remember_message_id(self, message_id: str) -> bool:
        if message_id in self._seen_message_ids:
            return False
        self._seen_message_ids.add(message_id)
        self._seen_message_order.append(message_id)
        if len(self._seen_message_order) > SEEN_MESSAGE_CACHE:
            oldest = self._seen_message_order.pop(0)
            self._seen_message_ids.discard(oldest)
        return True

    def _remember_delivery_id(self, delivery_id: str) -> bool:
        """Deduplicate delivery retries in their own namespace.

        Delivery IDs are server-owned and may legally equal a message ID; a
        global cache would incorrectly drop one of those unrelated frames.
        """
        if delivery_id in self._seen_delivery_ids:
            return False
        self._seen_delivery_ids.add(delivery_id)
        self._seen_delivery_order.append(delivery_id)
        if len(self._seen_delivery_order) > SEEN_MESSAGE_CACHE:
            oldest = self._seen_delivery_order.pop(0)
            self._seen_delivery_ids.discard(oldest)
        return True

    def _fail_ack_waiters(self, error: Exception) -> None:
        for waiter in list(self._ack_waiters.values()):
            if not waiter.done():
                waiter.set_exception(error)
        self._ack_waiters.clear()

    def _fail_request_waiters(self, error: Exception) -> None:
        for waiter in list(self._request_waiters.values()):
            if not waiter.done():
                waiter.set_exception(error)
        self._request_waiters.clear()

    def _release_inbound_tempdir(self, message_id: str) -> None:
        temp_dir = self._inbound_tempdirs.pop(message_id, None)
        if temp_dir is not None:
            temp_dir.cleanup()

    def supports_feature(self, feature: str) -> bool:
        """Return whether the connected peer explicitly negotiated *feature*.

        Legacy peers have no capability list, so only the original message path
        is usable. This is intentionally fail-closed for new event families.
        """
        required = {
            "typing": {"agent.typing", "typing"},
            "streaming": {"agent.start", "agent.delta", "agent.complete", "streaming"},
            "agent_state": {"agent.start", "agent.status", "agent.complete", "agent_state"},
            "tool_state": {"tool.started", "tool.progress", "tool.completed", "tool_state"},
            "clarify": {"clarify.request", "clarify"},
            "approval": {"approval.request", "approval"},
            "slash_commands": {"slash_commands", "slash.command", "command.request"},
            "cron_delivery": {"cron_delivery", "cron.delivery", "delivery.send"},
            "proactive_delivery": {"proactive_delivery", "proactive.delivery", "delivery.send"},
            "sessions": {"session.start", "session.update", "session.complete", "sessions"},
            "artifacts": {"artifact.completed", "artifacts"},
        }.get(feature, {feature})
        return self._negotiated and bool(required & self._server_capabilities)

    def _next_event_seq(self) -> int:
        self._event_seq += 1
        return self._event_seq

    async def _close_socket(self) -> None:
        ws, self._ws = self._ws, None
        if ws is not None:
            try:
                await ws.close()
            except Exception:
                logger.debug("[%s] WebSocket close failed", self.name, exc_info=True)

    async def _send_capabilities_probe(self) -> None:
        try:
            await asyncio.sleep(0.05)
            if self._ws is not None and self._running:
                await self._send_wire(protocol.capabilities_hello())
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.debug("[%s] capabilities negotiation probe failed", self.name, exc_info=True)

    async def _receive_loop(self) -> None:
        try:
            while self._running and self._ws is not None:
                raw = await self._ws.recv()
                await self._handle_wire(raw)
        except ConnectionClosed:
            logger.info("[%s] Orialis Server connection closed", self.name)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("[%s] Orialis Agent receive loop failed", self.name)
        finally:
            self._mark_disconnected()
            await self._close_socket()
            self._fail_ack_waiters(ConnectionError("Orialis Server connection closed"))
            self._fail_request_waiters(ConnectionError("Orialis Server connection closed"))
            for message_id in list(self._inbound_tempdirs):
                self._release_inbound_tempdir(message_id)
            if not self._manual_disconnect:
                self._connection_state = "disconnected"
                self._schedule_reconnect()

    async def _handle_wire(self, raw: Any) -> None:
        try:
            message = protocol.parse_message(raw)
        except protocol.ProtocolError as exc:
            logger.warning("[%s] rejected Orialis frame: %s", self.name, exc)
            if self._ws is not None:
                await self._send_wire(protocol.error(exc.code, str(exc)))
            return
        message_type = message["type"]
        if message_type == "ping":
            await self._send_wire(protocol.pong())
        elif message_type == "message.ack":
            waiter = self._ack_waiters.get(message["message_id"])
            if waiter is not None and not waiter.done():
                waiter.set_result(message["status"])
            request_waiter = self._request_waiters.get(message["message_id"])
            if request_waiter is not None and not request_waiter.done():
                request_waiter.set_result(message)
        elif message_type == "capabilities.ack":
            self._server_capabilities = protocol.capabilities_from_ack(message)
            self._negotiated = True
        elif message_type == "message.send":
            await self._dispatch_message(message)
        elif message_type in {"command.request", "slash.command"}:
            await self._dispatch_command(message)
        elif message_type in {"delivery.send", "cron.delivery", "proactive.delivery"}:
            await self._dispatch_delivery(message)
        elif message_type in {"clarify.response", "clarify.resolve", "clarify.cancel", "approval.response", "approval.resolve", "slash.reply"}:
            await self._handle_interaction_response(message)
        elif message_type in {"command.reply", "session.reply", "delivery.ack"}:
            self._resolve_request_waiter(message)
        elif message_type in {"session.open", "session.close", "session.reset", "session.list", "session.info"}:
            await self._handle_session_request(message)
        elif message_type in {"artifact", "artifact.event", "artifact.started", "artifact.created", "artifact.progress", "artifact.completed", "artifact.failed"}:
            event_id = message.get("event_id")
            if event_id and not self._remember_message_id(event_id):
                logger.info("[%s] ignored duplicate artifact event event_id=%s", self.name, event_id)
                return
            await self._dispatch_artifact(message)
        elif message_type in {"agent.typing", "agent.start", "agent.started", "agent.delta", "agent.complete", "agent.completed", "agent.error", "agent.failed", "agent.status", "tool.started", "tool.progress", "tool.completed", "tool.failed", "agent.state", "tool.state", "typing", "stream.start", "stream.delta", "stream.end"}:
            # The server normally receives these from Hermes. Accepting them on
            # input makes reconnect/replay forward-compatible and harmless.
            event_id = message.get("event_id")
            if event_id and not self._remember_message_id(event_id):
                logger.info("[%s] ignored duplicate structured event event_id=%s", self.name, event_id)
                return
            logger.debug("[%s] received Orialis event %s", self.name, message_type)
        elif message_type == "error":
            logger.error("[%s] Orialis Server error %s: %s", self.name, message["code"], message["message"])
        elif message_type in {"hello_ack", "pong"}:
            logger.debug("[%s] received %s", self.name, message_type)
        else:
            await self._send_wire(protocol.error("INVALID_MESSAGE", f"unsupported message type {message_type}"))

    def _remember_interaction(self, request_id: str) -> bool:
        now = time.monotonic()
        for pending_id, pending in list(self._pending_interactions.items()):
            if now >= pending.get("expires_at", 0):
                self._mark_interaction_resolved(pending_id)
        if request_id in self._resolved_interactions:
            return False
        return True

    def _mark_interaction_resolved(self, request_id: str) -> None:
        self._pending_interactions.pop(request_id, None)
        self._resolved_interactions[request_id] = time.monotonic()
        while len(self._resolved_interactions) > 512:
            self._resolved_interactions.popitem(last=False)

    async def _send_interaction_error(self, code: str, message: str, reply_to: Optional[str] = None) -> None:
        if self._ws is not None:
            await self._send_wire(protocol.error(code, message, reply_to=reply_to))

    def _resolve_request_waiter(self, message: Dict[str, Any]) -> None:
        request_id = message.get("delivery_id") or message.get("request_id")
        waiter = self._request_waiters.get(request_id)
        if waiter is not None and not waiter.done():
            waiter.set_result(message)

    async def _handle_interaction_response(self, message: Dict[str, Any]) -> None:
        request_id = message.get("request_id", "")
        pending = self._pending_interactions.get(request_id)
        if pending is None or not self._remember_interaction(request_id):
            await self._send_interaction_error("INTERACTION_NOT_PENDING", "interaction is unknown, expired, or already resolved", request_id)
            return
        if time.monotonic() >= pending["expires_at"]:
            self._mark_interaction_resolved(request_id)
            await self._send_interaction_error("INTERACTION_EXPIRED", "interaction response arrived after its deadline", request_id)
            return
        if pending.get("conversation_id") != message.get("conversation_id"):
            await self._send_interaction_error("INTERACTION_SCOPE_MISMATCH", "interaction belongs to another conversation", request_id)
            return
        kind = pending["kind"]
        resolved = False
        if kind == "clarify":
            try:
                from tools.clarify_gateway import resolve_gateway_clarify
                if message.get("type") == "clarify.cancel":
                    response = message.get("reason") or "cancelled"
                else:
                    response = message.get("response") or message.get("answer") or ""
                resolved = bool(resolve_gateway_clarify(request_id, response))
            except Exception:
                logger.warning("[%s] clarify response resolver failed", self.name, exc_info=True)
        elif kind == "approval":
            try:
                from tools.approval import resolve_gateway_approval
                resolved = bool(resolve_gateway_approval(
                    pending["session_key"], message.get("choice") or message.get("decision", "deny"), reason=message.get("reason"), request_id=request_id
                ))
            except Exception:
                logger.warning("[%s] approval response resolver failed", self.name, exc_info=True)
        elif kind == "slash":
            try:
                from tools.slash_confirm import resolve
                await resolve(pending["session_key"], request_id, message["choice"])
                # ``resolve`` intentionally returns the handler result, which may
                # itself be None. The pending entry is the authoritative duplicate
                # guard, and it was present immediately before this call.
                resolved = True
            except Exception:
                logger.warning("[%s] slash response resolver failed", self.name, exc_info=True)
        if not resolved:
            await self._send_interaction_error("INTERACTION_NOT_PENDING", "Hermes no longer has this interaction pending", request_id)
            return
        self._mark_interaction_resolved(request_id)
        await self._send_wire(protocol.ack(request_id, "resolved"))

    async def _dispatch_message(self, message: Dict[str, Any]) -> None:
        conversation_id = message["conversation_id"]
        message_id = message["message_id"]
        if not self._remember_message_id(message_id):
            await self._send_wire(protocol.ack(message_id))
            logger.info("[%s] ignored duplicate message.send message_id=%s", self.name, message_id)
            return
        await self._send_wire(protocol.ack(message_id))
        chat_id = chat_id_for_conversation(conversation_id)
        source = self.build_source(
            chat_id=chat_id,
            chat_name=conversation_id,
            chat_type="dm",
            user_id=self._orialis.device_id,
            user_name=self._orialis.device_id,
            message_id=message_id,
        )
        attachments = message.get("attachments", [])
        temp_dir = tempfile.TemporaryDirectory(prefix="orialis-inbound-")
        paths: list[str] = []
        media_types: list[str] = []
        failed = False
        for index, item in enumerate(attachments):
            try:
                name = _safe_filename(item["name"], f"attachment-{index + 1}")
                path = Path(temp_dir.name) / name
                media_types.append(await asyncio.to_thread(
                    _download_attachment, item, self._orialis.server_url, path,
                    self._orialis.device_token, self._orialis.device_id
                ))
                paths.append(str(path))
            except (OSError, ValueError, HTTPError, URLError, TimeoutError) as exc:
                failed = True
                logger.warning("[%s] attachment %s was not downloaded: %s", self.name, index, exc)
        if failed:
            temp_dir.cleanup()
            await self._send_wire(protocol.error(
                "ATTACHMENT_UNAVAILABLE",
                "one or more Orialis attachments could not be downloaded",
                reply_to=message_id,
            ))
            return
        self._inbound_tempdirs[message_id] = temp_dir
        event = MessageEvent(
            text=message.get("content", ""),
            message_type=(MessageType.PHOTO if media_types and media_types[0].startswith("image/")
                          else MessageType.DOCUMENT if media_types else MessageType.TEXT),
            user_id=self._orialis.device_id,
            user_name=self._orialis.device_id,
            source=source,
            raw_message=message,
            message_id=message_id,
            media_urls=paths,
            media_types=media_types,
        )
        logger.info(
            "[%s] message received type=message.send message_id=%s conversation_id=%s attachments=%d",
            self.name, message_id, conversation_id, len(paths),
        )
        self._reply_anchors[chat_id] = message_id
        try:
            await self.handle_message(event)
            # BasePlatformAdapter.handle_message returns immediately after it
            # claims the event. Keep files for the background turn; release
            # them immediately when no handler accepted it.
            if not getattr(event, "_gateway_accepted", False):
                self._release_inbound_tempdir(message_id)
        except Exception:
            self._release_inbound_tempdir(message_id)
            raise
        finally:
            self._reply_anchors.pop(chat_id, None)

    async def _dispatch_command(self, message: Dict[str, Any]) -> None:
        """Pass a server-originated Hermes slash command through the real gateway.

        ``MessageEvent.is_command`` remains authoritative, so normal Hermes
        authorization and command routing apply. The temporary command anchor
        makes the resulting response a correlated ``command.reply`` frame.
        """
        request_id = message["request_id"]
        if not self._remember_message_id(request_id):
            await self._send_wire(protocol.command_reply(
                request_id=request_id, conversation_id=message["conversation_id"], status="duplicate"
            ))
            return
        command = str(message.get("command", "")).strip()
        if not command.startswith("/"):
            command = "/" + command
        args = str(message.get("args", "") or "")
        text = f"{command} {args}".rstrip()
        chat_id = chat_id_for_conversation(message["conversation_id"])
        source = self.build_source(
            chat_id=chat_id, chat_name=message["conversation_id"], chat_type="dm",
            user_id=self._orialis.device_id, user_name=self._orialis.device_id,
            message_id=request_id,
        )
        event = MessageEvent(
            text=text, message_type=MessageType.COMMAND,
            user_id=self._orialis.device_id, user_name=self._orialis.device_id,
            source=source, raw_message=message, message_id=request_id,
            metadata={"orialis_request_id": request_id, "event_type": message["type"]},
        )
        self._reply_anchors[chat_id] = request_id
        self._command_anchors[chat_id] = request_id
        try:
            await self.handle_message(event)
        finally:
            self._command_anchors.pop(chat_id, None)
            self._reply_anchors.pop(chat_id, None)

    async def _dispatch_delivery(self, message: Dict[str, Any]) -> None:
        """Deliver cron/proactive input without allowing payload text to invoke controls."""
        delivery_id = message["delivery_id"]
        if not self._remember_delivery_id(delivery_id):
            await self._send_wire({
                "version": protocol.PROTOCOL_VERSION, "type": "delivery.ack",
                "delivery_id": delivery_id, "status": "duplicate",
            })
            return
        chat_id = chat_id_for_conversation(message["conversation_id"])
        source = self.build_source(
            chat_id=chat_id, chat_name=message["conversation_id"], chat_type="dm",
            user_id=self._orialis.device_id, user_name=self._orialis.device_id,
            message_id=delivery_id,
        )
        await self._send_wire({
            "version": protocol.PROTOCOL_VERSION, "type": "delivery.ack",
            "delivery_id": delivery_id, "conversation_id": message["conversation_id"], "status": "received",
        })
        event = MessageEvent(
            text=message.get("content", ""), message_type=MessageType.TEXT,
            user_id=self._orialis.device_id, user_name=self._orialis.device_id,
            source=source, raw_message=message, message_id=delivery_id,
            metadata={"event_type": message["type"], **(message.get("metadata") or {})},
            allow_gateway_control=False,
        )
        self._reply_anchors[chat_id] = delivery_id
        try:
            await self.handle_message(event)
        finally:
            self._reply_anchors.pop(chat_id, None)

    async def _dispatch_artifact(self, message: Dict[str, Any]) -> None:
        """Expose an artifact event to Hermes as metadata, never as executable content."""
        artifact_payload = message.get("artifact") if isinstance(message.get("artifact"), dict) else {}
        artifact_id = str(message.get("artifact_id") or artifact_payload.get("id") or "")
        if not artifact_id:
            return
        if not self._remember_message_id(artifact_id):
            return
        conversation_id = message.get("conversation_id") or self._orialis.home_channel
        if not conversation_id:
            logger.warning("[%s] artifact %s has no conversation target", self.name, artifact_id)
            return
        chat_id = chat_id_for_conversation(conversation_id)
        source = self.build_source(
            chat_id=chat_id, chat_name=conversation_id, chat_type="dm",
            user_id=self._orialis.device_id, user_name=self._orialis.device_id,
            message_id=artifact_id,
        )
        event = MessageEvent(
            text=str(message.get("content") or message.get("message") or f"Artifact available: {message.get('name') or artifact_payload.get('name') or artifact_id}"),
            message_type=MessageType.DOCUMENT,
            user_id=self._orialis.device_id, user_name=self._orialis.device_id,
            source=source, raw_message=message, message_id=artifact_id,
            metadata={"artifact": message, "event_type": message["type"]},
            allow_gateway_control=False,
        )
        await self.handle_message(event)

    async def _handle_session_request(self, message: Dict[str, Any]) -> None:
        """Acknowledge server session commands; Hermes session state stays host-owned."""
        request_id = message["request_id"]
        conversation_id = message.get("conversation_id") or ""
        if self._ws is not None:
            await self._send_wire({
                "version": protocol.PROTOCOL_VERSION, "type": "session.reply",
                "request_id": request_id, "conversation_id": conversation_id,
                "status": "accepted",
            })

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if self._ws is None or not self._running:
            return SendResult(success=False, error="Orialis Server connection is not available", retryable=True)
        reply_to = reply_to or self._reply_anchors.get(chat_id)
        metadata = metadata or {}
        if metadata.get("force_proactive_send") or metadata.get("proactive"):
            if self.supports_feature("proactive_delivery") or self.supports_feature("cron_delivery"):
                return await self._send_delivery(
                    chat_id, content, metadata=metadata,
                    kind="proactive.delivery",
                )
        if not reply_to:
            return SendResult(success=False, error="Orialis reply is missing reply_to message id")
        conversation_id = conversation_id_for_chat_id(chat_id)
        message_id = f"msg_{uuid.uuid4().hex[:12]}"
        attachments = metadata.get("attachments")
        command_id = self._command_anchors.get(chat_id)
        if command_id and self.supports_feature("slash_commands"):
            message = protocol.command_reply(
                request_id=command_id, conversation_id=conversation_id,
                status="completed", content=content,
            )
        else:
            message = protocol.reply(
                message_id=message_id, reply_to=reply_to, conversation_id=conversation_id,
                content=content, attachments=attachments,
            )
        loop = asyncio.get_running_loop()
        ack_waiter = loop.create_future()
        ack_key = message_id if message["type"] == "message.reply" else command_id
        self._ack_waiters[ack_key] = ack_waiter
        try:
            await self._send_wire(message)
            await asyncio.wait_for(asyncio.shield(ack_waiter), timeout=self._orialis.ack_timeout_seconds)
            logger.info(
                "[%s] message sent type=message.reply message_id=%s conversation_id=%s reply_to=%s",
                self.name, message_id, conversation_id, reply_to,
            )
            return SendResult(success=True, message_id=message_id if message["type"] == "message.reply" else command_id)
        except Exception as exc:
            logger.error("[%s] could not send Hermes reply to Orialis Server: %s", self.name, exc)
            if isinstance(exc, asyncio.TimeoutError):
                error = "Orialis Server acknowledgement timed out"
            else:
                error = "Orialis Server send failed"
            return SendResult(success=False, error=error, retryable=True)
        finally:
            self._ack_waiters.pop(ack_key, None)

    async def _send_delivery(
        self, chat_id: str, content: str, *, metadata: Optional[Dict[str, Any]] = None,
        kind: str = "proactive.delivery", delivery_id: Optional[str] = None,
    ) -> SendResult:
        """Send a proactive/cron message with an idempotent delivery receipt."""
        conversation_id = conversation_id_for_chat_id(chat_id)
        delivery_id = delivery_id or f"delivery_{uuid.uuid4().hex[:12]}"
        message = protocol.delivery(
            delivery_id=delivery_id, conversation_id=conversation_id, content=content, kind=kind,
            metadata={k: v for k, v in (metadata or {}).items() if k != "attachments"},
            attachments=(metadata or {}).get("attachments"),
        )
        loop = asyncio.get_running_loop()
        waiter = loop.create_future()
        self._request_waiters[delivery_id] = waiter
        try:
            await self._send_wire(message)
            response = await asyncio.wait_for(asyncio.shield(waiter), timeout=self._orialis.ack_timeout_seconds)
            status = response.get("status") if isinstance(response, dict) else "received"
            if status not in {"received", "accepted", "duplicate"}:
                return SendResult(success=False, error=f"Orialis delivery rejected: {status}", retryable=True)
            return SendResult(success=True, message_id=delivery_id, raw_response=response)
        except asyncio.TimeoutError:
            return SendResult(success=False, error="Orialis delivery acknowledgement timed out", retryable=True)
        except Exception:
            return SendResult(success=False, error="Orialis proactive delivery failed", retryable=True)
        finally:
            self._request_waiters.pop(delivery_id, None)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        if not self.supports_feature("typing") or self._ws is None or not self._running:
            return
        conversation_id = conversation_id_for_chat_id(chat_id)
        try:
            await self._send_wire(protocol.agent_typing(
                conversation_id=conversation_id, typing=True, session_id=self._session_id,
                seq=self._next_event_seq(), run_id=(metadata or {}).get("run_id"),
            ))
        except Exception:
            logger.debug("[%s] typing notification failed", self.name, exc_info=True)

    async def stop_typing(self, chat_id: str, metadata=None) -> None:
        if not self.supports_feature("typing") or self._ws is None or not self._running:
            return
        try:
            await self._send_wire(protocol.agent_typing(
                conversation_id=conversation_id_for_chat_id(chat_id), typing=False, session_id=self._session_id,
                seq=self._next_event_seq(), run_id=(metadata or {}).get("run_id"),
            ))
        except Exception:
            logger.debug("[%s] typing-stop notification failed", self.name, exc_info=True)

    def supports_native_streaming(self, chat_id=None, chat_type=None, metadata=None) -> bool:
        return self.supports_feature("streaming") and self._ws is not None and self._running

    def _schedule_wire(self, message: Dict[str, Any]) -> None:
        """Schedule a frame from Hermes' synchronous stream formatter thread."""
        loop = self._loop
        if loop is None or loop.is_closed() or self._ws is None or not self._running:
            return

        def start() -> None:
            if self._ws is None or not self._running:
                return
            task = asyncio.create_task(self._send_wire(message), name="orialis-event-send")
            self._scheduled_wire_tasks.add(task)
            task.add_done_callback(self._scheduled_wire_tasks.discard)
            task.add_done_callback(self._log_scheduled_wire_failure)

        loop.call_soon_threadsafe(start)

    def _log_scheduled_wire_failure(self, task: asyncio.Task) -> None:
        if not task.cancelled() and task.exception() is not None:
            logger.debug("[%s] asynchronous Orialis event send failed: %s", self.name, task.exception())

    async def send_stream_frame(
        self, content: str, *, finalize: bool = False, chat_id: str, reply_to: Optional[str] = None,
        turn_id: Optional[str] = None,
    ) -> bool:
        """Bridge Hermes' real stream consumer to structured Orialis frames."""
        if not self.supports_native_streaming(chat_id=chat_id):
            return False
        turn_id = turn_id or uuid.uuid4().hex
        context = self._active_streams.get(turn_id)
        if context is None:
            context = {
                "stream_id": f"stream_{uuid.uuid4().hex[:16]}",
                "conversation_id": conversation_id_for_chat_id(chat_id), "sequence": 0,
                "reply_to": reply_to,
            }
            self._active_streams[turn_id] = context
            self._stream_context = {**context, "chat_id": chat_id, "turn_id": turn_id}
            try:
                await self._send_wire(protocol.agent_start(
                    conversation_id=context["conversation_id"], run_id=turn_id,
                    session_id=self._session_id, seq=self._next_event_seq(), stream_id=context["stream_id"],
                ))
            except Exception:
                self._active_streams.pop(turn_id, None)
                return False
        try:
            if content:
                await self._send_wire(protocol.agent_delta(
                    conversation_id=context["conversation_id"], run_id=turn_id, delta=content,
                    session_id=self._session_id, seq=self._next_event_seq(), stream_id=context["stream_id"],
                ))
                context["sequence"] += 1
            if finalize:
                await self._send_wire(protocol.agent_complete(
                    conversation_id=context["conversation_id"], run_id=turn_id,
                    session_id=self._session_id, seq=self._next_event_seq(), result={"stream_id": context["stream_id"]},
                ))
                self._active_streams.pop(turn_id, None)
                self._stream_context = {}
            return True
        except Exception:
            logger.debug("[%s] structured stream frame failed", self.name, exc_info=True)
            return False

    async def send_agent_state(self, chat_id: str, state: str, *, run_id: Optional[str] = None, message: Optional[str] = None) -> bool:
        if not self.supports_feature("agent_state"):
            return False
        try:
            conversation_id = conversation_id_for_chat_id(chat_id)
            run_id = run_id or f"run_{uuid.uuid4().hex[:16]}"
            if state in {"start", "started", "running"}:
                if not (self.supports_feature("agent.start") or (self._negotiated and "agent_state" in self._server_capabilities)):
                    return False
                frame = protocol.agent_start(
                    conversation_id=conversation_id, run_id=run_id, session_id=self._session_id,
                    seq=self._next_event_seq(), status=state,
                )
            elif state in {"complete", "completed", "success"}:
                if not (self.supports_feature("agent.complete") or (self._negotiated and "agent_state" in self._server_capabilities)):
                    return False
                frame = protocol.agent_complete(
                    conversation_id=conversation_id, run_id=run_id, session_id=self._session_id,
                    seq=self._next_event_seq(), result={"message": message} if message else None,
                )
            elif state in {"error", "failed", "failure"}:
                if not (self.supports_feature("agent.error") or (self._negotiated and "agent_state" in self._server_capabilities)):
                    return False
                frame = protocol.agent_error(
                    conversation_id=conversation_id, run_id=run_id, code="HERMES_AGENT_FAILED",
                    message=message or state, session_id=self._session_id, seq=self._next_event_seq(),
                )
            else:
                if not (self.supports_feature("agent.status") or (self._negotiated and "agent_state" in self._server_capabilities)):
                    return False
                frame = protocol.agent_status(
                    conversation_id=conversation_id, status=state, run_id=run_id, message=message,
                    session_id=self._session_id, seq=self._next_event_seq(),
                )
            await self._send_wire(frame)
            return True
        except Exception:
            return False

    async def send_tool_state(self, chat_id: str, *, tool_call_id: str, state: str, tool_name: Optional[str] = None, run_id: Optional[str] = None, data: Any = None) -> bool:
        if not self.supports_feature("tool_state"):
            return False
        try:
            event_type = {"started": "tool.started", "start": "tool.started", "completed": "tool.completed", "failed": "tool.failed"}.get(state, "tool.progress")
            if not (self.supports_feature(event_type) or (self._negotiated and "tool_state" in self._server_capabilities)):
                return False
            fields = {
                "conversation_id": conversation_id_for_chat_id(chat_id), "tool_call_id": tool_call_id,
                "session_id": self._session_id, "seq": self._next_event_seq(), "run_id": run_id,
                "tool_name": tool_name or "tool", "progress": data, "output": data,
                "code": "HERMES_TOOL_FAILED" if event_type == "tool.failed" else None,
                "message": str(data) if event_type == "tool.failed" and data is not None else None,
            }
            await self._send_wire(protocol.tool_event(event_type=event_type, event_id=None, **fields))
            return True
        except Exception:
            return False

    def format_tool_event(self, event: Any, *, mode: str = "all", preview_max_len: int = 40) -> Optional[str]:
        """Keep Hermes' native text progress and mirror a structured tool-start event."""
        line = super().format_tool_event(event, mode=mode, preview_max_len=preview_max_len)
        context = self._stream_context
        if context and self.supports_feature("tool_state"):
            tool_name = getattr(event, "tool_name", "tool")
            index = getattr(event, "index", 0)
            self._schedule_wire(protocol.tool_event(
                event_type="tool.started", conversation_id=context["conversation_id"],
                tool_call_id=f"{context['turn_id']}:{index}", session_id=self._session_id,
                seq=self._next_event_seq(), tool_name=tool_name, run_id=context["turn_id"],
                progress={"preview": getattr(event, "preview", None), "args": getattr(event, "args", None)},
            ))
        return line

    async def send_clarify(
        self, chat_id: str, question: str, choices: Optional[list], clarify_id: str,
        session_key: str, metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if not self.supports_feature("clarify"):
            return await super().send_clarify(
                chat_id=chat_id, question=question, choices=choices, clarify_id=clarify_id,
                session_key=session_key, metadata=metadata,
            )
        multi_select = False
        try:
            from tools import clarify_gateway as clarify_mod
            with clarify_mod._lock:
                multi_select = bool(getattr(clarify_mod._entries.get(clarify_id), "multi_select", False))
        except Exception:
            pass
        conversation_id = conversation_id_for_chat_id(chat_id)
        self._pending_interactions[clarify_id] = {
            "kind": "clarify", "session_key": session_key, "conversation_id": conversation_id,
            "expires_at": time.monotonic() + self._orialis.interaction_timeout_seconds,
        }
        message = protocol.clarify_event(
            event_type="clarify.request", request_id=clarify_id, conversation_id=conversation_id,
            question=question, choices=choices, session_id=self._session_id,
            seq=self._next_event_seq(), multi_select=multi_select,
        )
        message["session_key"] = session_key
        reply_to = (metadata or {}).get("reply_to_message_id") or self._reply_anchors.get(chat_id)
        if reply_to:
            message["reply_to"] = reply_to
        result = await self._send_feature_request(message, clarify_id)
        if not result.success:
            self._pending_interactions.pop(clarify_id, None)
        return result

    async def _send_exec_approval_prompt(self, prompt: Any) -> SendResult:
        if not self.supports_feature("approval"):
            return SendResult(success=False, error="Orialis approval capability was not negotiated")
        request_id = ""
        try:
            from tools.approval import get_pending_gateway_approval
            pending = get_pending_gateway_approval(prompt.session_key)
            request_id = str((pending or {}).get("request_id") or "")
        except Exception:
            pending = None
        if not request_id:
            # Direct callers may exercise the adapter without first installing
            # Hermes' approval queue; the generated id is still safe and bound.
            request_id = f"approval_{uuid.uuid4().hex[:16]}"
        self._pending_interactions[request_id] = {
            "kind": "approval", "session_key": prompt.session_key,
            "conversation_id": conversation_id_for_chat_id(prompt.chat_id),
            "expires_at": time.monotonic() + self._orialis.interaction_timeout_seconds,
        }
        message = protocol.approval_event(
            event_type="approval.request", request_id=request_id,
            conversation_id=conversation_id_for_chat_id(prompt.chat_id), action=prompt.command,
            session_id=self._session_id, seq=self._next_event_seq(),
        )
        message.update({
            "session_key": prompt.session_key, "command": prompt.command,
            "description": prompt.description, "choices": list(prompt.choices),
            "timeout_seconds": self._orialis.interaction_timeout_seconds,
            "smart_denied": prompt.smart_denied,
        })
        reply_to = (prompt.metadata or {}).get("reply_to_message_id") or self._reply_anchors.get(prompt.chat_id)
        if reply_to:
            message["reply_to"] = reply_to
        result = await self._send_feature_request(message, request_id)
        if not result.success:
            self._pending_interactions.pop(request_id, None)
        return result

    async def send_slash_confirm(
        self, chat_id: str, title: str, message: str, session_key: str, confirm_id: str,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if not self.supports_feature("slash_commands"):
            return SendResult(success=False, error="Orialis slash-command capability was not negotiated")
        self._pending_interactions[confirm_id] = {
            "kind": "slash", "session_key": session_key,
            "conversation_id": conversation_id_for_chat_id(chat_id),
            "expires_at": time.monotonic() + self._orialis.interaction_timeout_seconds,
        }
        frame = protocol.slash_command(
            request_id=confirm_id, conversation_id=conversation_id_for_chat_id(chat_id),
            command=title, args=message, session_key=session_key,
        )
        result = await self._send_feature_request(frame, confirm_id)
        if not result.success:
            self._pending_interactions.pop(confirm_id, None)
        return result

    async def _send_feature_request(self, message: Dict[str, Any], request_id: str) -> SendResult:
        """Send a negotiated request and wait for its transport receipt."""
        if self._ws is None or not self._running:
            return SendResult(success=False, error="Orialis Server connection is not available", retryable=True)
        loop = asyncio.get_running_loop()
        waiter = loop.create_future()
        self._ack_waiters[request_id] = waiter
        try:
            await self._send_wire(message)
            await asyncio.wait_for(asyncio.shield(waiter), timeout=self._orialis.ack_timeout_seconds)
            return SendResult(success=True, message_id=request_id)
        except asyncio.TimeoutError:
            return SendResult(success=False, error="Orialis request acknowledgement timed out", retryable=True)
        except Exception:
            return SendResult(success=False, error="Orialis request failed", retryable=True)
        finally:
            self._ack_waiters.pop(request_id, None)

    async def request_session(
        self, action: str, chat_id: str, *, session_id: Optional[str] = None,
        data: Optional[Mapping[str, Any]] = None,
    ) -> SendResult:
        if not self.supports_feature("sessions"):
            return SendResult(success=True, raw_response={"fallback": "hermes_session_store", "action": action})
        request_id = f"session_{uuid.uuid4().hex[:16]}"
        frame = protocol.session_request(
            action=action, request_id=request_id, session_id=session_id,
            conversation_id=conversation_id_for_chat_id(chat_id), data=data,
        )
        if self._ws is None or not self._running:
            return SendResult(success=False, error="Orialis Server connection is not available", retryable=True)
        loop = asyncio.get_running_loop()
        waiter = loop.create_future()
        self._request_waiters[request_id] = waiter
        try:
            await self._send_wire(frame)
            response = await asyncio.wait_for(asyncio.shield(waiter), timeout=self._orialis.ack_timeout_seconds)
            return SendResult(success=response.get("status") in {"accepted", "completed", "received"}, message_id=request_id, raw_response=response)
        except asyncio.TimeoutError:
            return SendResult(success=False, error="Orialis session request timed out", retryable=True)
        except Exception:
            return SendResult(success=False, error="Orialis session request failed", retryable=True)
        finally:
            self._request_waiters.pop(request_id, None)

    async def open_session(self, chat_id: str, session_id: Optional[str] = None) -> SendResult:
        return await self.request_session("open", chat_id, session_id=session_id)

    async def close_session(self, chat_id: str, session_id: str) -> SendResult:
        return await self.request_session("close", chat_id, session_id=session_id)

    async def reset_session(self, chat_id: str, session_id: str) -> SendResult:
        return await self.request_session("reset", chat_id, session_id=session_id)

    async def list_sessions(self, chat_id: str) -> SendResult:
        return await self.request_session("list", chat_id)

    async def session_info(self, chat_id: str, session_id: str) -> SendResult:
        return await self.request_session("info", chat_id, session_id=session_id)

    async def send_artifact(
        self, chat_id: str, file_path: str, *, name: Optional[str] = None,
        caption: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if not self.supports_feature("artifacts"):
            return await self._send_file(chat_id, file_path, caption, self._reply_anchors.get(chat_id), metadata, file_name=name)
        try:
            attachment = await asyncio.to_thread(
                _upload_attachment, file_path, self._orialis.server_url,
                conversation_id_for_chat_id(chat_id), self._orialis.device_token, self._orialis.device_id,
            )
            frame = protocol.artifact_completed(
                artifact_id=f"artifact_{uuid.uuid4().hex[:16]}",
                conversation_id=conversation_id_for_chat_id(chat_id), name=_safe_filename(name or attachment["name"]),
                mime_type=attachment["mime_type"], uri=attachment["download_url"],
                size=attachment.get("size"), metadata={**(metadata or {}), "caption": caption or ""},
                session_id=self._session_id, seq=self._next_event_seq(),
            )
            await self._send_wire(frame)
            return SendResult(success=True, message_id=frame["artifact_id"], raw_response=frame)
        except (OSError, ValueError, HTTPError, URLError, TimeoutError):
            return SendResult(success=False, error="Orialis artifact upload failed", retryable=True)

    async def _send_file(
        self, chat_id: str, file_path: str, caption: Optional[str], reply_to: Optional[str],
        metadata: Optional[Dict[str, Any]], *, file_name: Optional[str] = None,
    ) -> SendResult:
        if not reply_to:
            return SendResult(success=False, error="Orialis reply is missing reply_to message id")
        if self._ws is None or not self._running:
            return SendResult(success=False, error="Orialis Server connection is not available", retryable=True)
        try:
            attachment = await asyncio.to_thread(
                _upload_attachment, file_path, self._orialis.server_url,
                conversation_id_for_chat_id(chat_id), self._orialis.device_token,
                self._orialis.device_id,
            )
            if file_name:
                attachment["name"] = _safe_filename(file_name)
            return await self.send(
                chat_id, caption or "", reply_to=reply_to,
                metadata={**(metadata or {}), "attachments": [attachment]},
            )
        except (OSError, ValueError, HTTPError, URLError, TimeoutError) as exc:
            logger.warning("[%s] could not upload attachment %s: %s", self.name, file_path, exc)
            return SendResult(success=False, error="Orialis attachment upload failed", retryable=True)

    async def send_image_file(self, chat_id: str, image_path: str, caption: Optional[str] = None,
                              reply_to: Optional[str] = None, metadata: Optional[Dict[str, Any]] = None,
                              **kwargs: Any) -> SendResult:
        mime = mimetypes.guess_type(image_path)[0] or "application/octet-stream"
        if not mime.startswith("image/"):
            return SendResult(success=False, error="file is not an image")
        return await self._send_file(chat_id, image_path, caption, reply_to, metadata)

    async def send_document(self, chat_id: str, file_path: str, caption: Optional[str] = None,
                            file_name: Optional[str] = None, reply_to: Optional[str] = None,
                            metadata: Optional[Dict[str, Any]] = None, **kwargs: Any) -> SendResult:
        return await self._send_file(chat_id, file_path, caption, reply_to, metadata, file_name=file_name)

    async def _send_wire(self, message: Dict[str, Any]) -> None:
        if self._ws is None:
            raise ConnectionError("WebSocket is not connected")
        payload = protocol.encode(message)
        async with self._send_lock:
            await self._ws.send(payload)

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        conversation_id = conversation_id_for_chat_id(chat_id)
        return {"name": conversation_id, "type": "dm", "chat_id": chat_id}

    async def on_processing_start(self, event: MessageEvent) -> None:
        await super().on_processing_start(event)
        chat_id = getattr(getattr(event, "source", None), "chat_id", None)
        if chat_id:
            await self.send_agent_state(chat_id, "started", run_id=getattr(event, "message_id", None))

    async def on_processing_complete(self, event: MessageEvent, outcome: Any) -> None:
        await super().on_processing_complete(event, outcome)
        if getattr(event, "message_id", None):
            self._release_inbound_tempdir(event.message_id)
        chat_id = getattr(getattr(event, "source", None), "chat_id", None)
        if chat_id:
            state = getattr(outcome, "value", str(outcome)).lower()
            await self.send_agent_state(chat_id, state, run_id=getattr(event, "message_id", None))


async def _standalone_send(
    platform_config: Any,
    chat_id: str,
    message: str,
    *,
    thread_id: Optional[str] = None,
    media_files: Optional[list[str]] = None,
    force_document: bool = False,
    **_: Any,
) -> dict[str, Any]:
    """Deliver a cron message when Hermes has no live adapter process."""
    if websockets is None:
        return {"error": "websockets package is not installed"}
    config = OrialisConfig.from_platform_config(platform_config)
    if not config.server_url or not config.device_id:
        return {"error": "Orialis server URL and device ID are required"}
    try:
        conversation_id = conversation_id_for_chat_id(str(chat_id))
    except ValueError:
        conversation_id = str(chat_id)
    headers: Dict[str, str] = {}
    if config.device_token:
        headers["Authorization"] = f"Bearer {config.device_token}"
    kwargs: Dict[str, Any] = {"ping_interval": 30, "ping_timeout": 60}
    if headers:
        kwargs["additional_headers"] = headers
    ws = None
    try:
        ws = await websockets.connect(config.server_url, **kwargs)
        await ws.send(protocol.encode(protocol.hello(
            config.device_id, plugin_version=PLUGIN_VERSION, platform=_platform_name(),
            capabilities=sorted(protocol.SUPPORTED_CAPABILITIES),
        )))
        hello_ack = protocol.parse_message(await asyncio.wait_for(ws.recv(), timeout=15))
        if hello_ack.get("type") != "hello_ack":
            return {"error": "Orialis handshake did not return hello_ack"}
        capabilities = protocol.capabilities_from_ack(hello_ack)
        if "cron_delivery" not in capabilities and "proactive_delivery" not in capabilities:
            return {"error": "Orialis Server does not support delivery capability"}
        attachments: list[Dict[str, Any]] = []
        for media_file in media_files or []:
            attachment = await asyncio.to_thread(
                _upload_attachment, str(Path(media_file)), config.server_url,
                conversation_id, config.device_token, config.device_id,
            )
            if force_document:
                attachment["name"] = _safe_filename(attachment.get("name", "attachment"))
            attachments.append(attachment)
        delivery_id = f"delivery_{uuid.uuid4().hex[:16]}"
        frame = protocol.delivery(
            delivery_id=delivery_id, conversation_id=conversation_id, content=message,
            kind="cron.delivery", metadata={"thread_id": thread_id} if thread_id else None,
            attachments=attachments or None,
        )
        await ws.send(protocol.encode(frame))
        response = protocol.parse_message(await asyncio.wait_for(ws.recv(), timeout=config.ack_timeout_seconds))
        response_id = response.get("delivery_id") or response.get("message_id")
        if response_id != delivery_id:
            return {"error": "Orialis delivery acknowledgement id mismatch"}
        status = response.get("status")
        if status not in {"received", "accepted", "duplicate"}:
            return {"error": f"Orialis delivery rejected: {status}"}
        return {"success": True, "delivery_id": delivery_id, "status": status}
    except (OSError, ValueError, TimeoutError, ConnectionError) as exc:
        return {"error": f"Orialis standalone delivery failed: {exc}"}
    finally:
        if ws is not None:
            try:
                await ws.close()
            except Exception:
                logger.debug("[%s] standalone WebSocket close failed", "orialis", exc_info=True)


def register(ctx) -> None:
    ctx.register_platform(
        name="orialis",
        label="Orialis",
        adapter_factory=OrialisAdapter,
        check_fn=check_requirements,
        validate_config=validate,
        required_env=["ORIALIS_SERVER_URL", "ORIALIS_DEVICE_ID"],
        cron_deliver_env_var="ORIALIS_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,
        env_enablement_fn=env_enablement,
        allowed_users_env="ORIALIS_ALLOWED_USERS",
        allow_all_env="ORIALIS_ALLOW_ALL_USERS",
        emoji="🔗",
        platform_hint=(
            "You are communicating through the Orialis Agent Gateway. "
            "Use plain text unless the user asks for a structured response. "
            "The read-only `orialis_capabilities` tool reports the Orialis "
            "Server API capabilities and the plugin's supported message operations. "
            "The reported server capabilities are API categories, not automatically "
            "callable Hermes tools; only use an operation when an explicit Hermes "
            "tool exposes it."
        ),
    )
