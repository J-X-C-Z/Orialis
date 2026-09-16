"""Hermes platform adapter for the Orialis Server Agent Gateway."""

from __future__ import annotations

import asyncio
import logging
import platform as host_platform
import uuid
from typing import Any, Dict, Optional

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

PLUGIN_VERSION = "0.1.0"
ACK_TIMEOUT_SECONDS = 10.0
RECONNECT_INITIAL_DELAY_SECONDS = 1.0
RECONNECT_MAX_DELAY_SECONDS = 30.0
SEEN_MESSAGE_CACHE = 4096


def check_requirements() -> bool:
    return websockets is not None


def _platform_name() -> str:
    value = host_platform.system().lower()
    return {"darwin": "macos", "windows": "windows"}.get(value, value)


class OrialisAdapter(BasePlatformAdapter):
    """Thin WebSocket bridge; Hermes remains responsible for agent execution."""

    supports_code_blocks = False
    interactive_resume = False

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
                    self._orialis.device_id, plugin_version=PLUGIN_VERSION, platform=_platform_name()
                ))
                raw_ack = await asyncio.wait_for(self._ws.recv(), timeout=15)
                ack = protocol.parse_message(raw_ack)
                if not isinstance(ack, dict) or ack.get("type") != "hello_ack":
                    raise protocol.ProtocolError("expected hello_ack during handshake")
                self._mark_connected()
                self._connection_state = "connected"
                self._reader_task = asyncio.create_task(self._receive_loop(), name="orialis-agent-reader")
                self._wire_plugin_handlers(None)
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
        task, self._reader_task = self._reader_task, None
        if task and task is not asyncio.current_task():
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
        await self._close_socket()
        self._fail_ack_waiters(ConnectionError("Orialis Server connection closed"))
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

    def _fail_ack_waiters(self, error: Exception) -> None:
        for waiter in list(self._ack_waiters.values()):
            if not waiter.done():
                waiter.set_exception(error)
        self._ack_waiters.clear()

    async def _close_socket(self) -> None:
        ws, self._ws = self._ws, None
        if ws is not None:
            try:
                await ws.close()
            except Exception:
                logger.debug("[%s] WebSocket close failed", self.name, exc_info=True)

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
        elif message_type == "message.send":
            await self._dispatch_message(message)
        elif message_type == "error":
            logger.error("[%s] Orialis Server error %s: %s", self.name, message["code"], message["message"])
        elif message_type in {"hello_ack", "pong"}:
            logger.debug("[%s] received %s", self.name, message_type)
        else:
            await self._send_wire(protocol.error("INVALID_MESSAGE", f"unsupported message type {message_type}"))

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
        event = MessageEvent(
            text=message["content"],
            message_type=MessageType.TEXT,
            user_id=self._orialis.device_id,
            user_name=self._orialis.device_id,
            source=source,
            raw_message=message,
            message_id=message_id,
        )
        logger.info(
            "[%s] message received type=message.send message_id=%s conversation_id=%s",
            self.name, message_id, conversation_id,
        )
        await self.handle_message(event)

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if self._ws is None or not self._running:
            return SendResult(success=False, error="Orialis Server connection is not available", retryable=True)
        if not reply_to:
            return SendResult(success=False, error="Orialis reply is missing reply_to message id")
        conversation_id = conversation_id_for_chat_id(chat_id)
        message_id = f"msg_{uuid.uuid4().hex[:12]}"
        message = protocol.reply(
            message_id=message_id,
            reply_to=reply_to,
            conversation_id=conversation_id,
            content=content,
        )
        loop = asyncio.get_running_loop()
        ack_waiter = loop.create_future()
        self._ack_waiters[message_id] = ack_waiter
        try:
            await self._send_wire(message)
            await asyncio.wait_for(asyncio.shield(ack_waiter), timeout=ACK_TIMEOUT_SECONDS)
            logger.info(
                "[%s] message sent type=message.reply message_id=%s conversation_id=%s reply_to=%s",
                self.name, message_id, conversation_id, reply_to,
            )
            return SendResult(success=True, message_id=message_id)
        except Exception as exc:
            logger.error("[%s] could not send Hermes reply to Orialis Server: %s", self.name, exc)
            if isinstance(exc, asyncio.TimeoutError):
                error = "Orialis Server acknowledgement timed out"
            else:
                error = "Orialis Server send failed"
            return SendResult(success=False, error=error, retryable=True)
        finally:
            self._ack_waiters.pop(message_id, None)

    async def _send_wire(self, message: Dict[str, Any]) -> None:
        if self._ws is None:
            raise ConnectionError("WebSocket is not connected")
        payload = protocol.encode(message)
        async with self._send_lock:
            await self._ws.send(payload)

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        conversation_id = conversation_id_for_chat_id(chat_id)
        return {"name": conversation_id, "type": "dm", "chat_id": chat_id}


def register(ctx) -> None:
    ctx.register_platform(
        name="orialis",
        label="Orialis",
        adapter_factory=OrialisAdapter,
        check_fn=check_requirements,
        validate_config=validate,
        required_env=["ORIALIS_SERVER_URL", "ORIALIS_DEVICE_ID"],
        env_enablement_fn=env_enablement,
        allowed_users_env="ORIALIS_ALLOWED_USERS",
        allow_all_env="ORIALIS_ALLOW_ALL_USERS",
        emoji="🔗",
        platform_hint=(
            "You are communicating through the Orialis Agent Gateway. "
            "Use plain text unless the user asks for a structured response."
        ),
    )
