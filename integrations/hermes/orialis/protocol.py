"""Strict, dependency-light Orialis Agent Gateway protocol helpers.

The wire format deliberately stays a flat JSON object. Hermes 0.2 peers only
know the message/attachment subset; newer peers advertise extra capabilities in
``hello_ack`` and the adapter has a safe, explicit fallback for every new feature.
"""

from __future__ import annotations

import json
import re
import uuid
from datetime import date, datetime
from typing import Any, Mapping, Optional, Sequence

PROTOCOL_VERSION = 1
SUPPORTED_CAPABILITIES = frozenset({
    "agent.typing", "agent.start", "agent.delta", "agent.complete", "agent.error", "agent.status",
    "tool.started", "tool.progress", "tool.completed", "tool.failed",
    "clarify.request", "clarify.resolve", "clarify.cancel",
    "approval.request", "approval.resolve",
    "session.start", "session.update", "session.complete", "session.cancel", "session.error",
    "artifact.started", "artifact.progress", "artifact.completed", "artifact.failed",
})
HELPER_CAPABILITIES = frozenset({
    "typing", "streaming", "agent_state", "tool_state", "clarify", "approval",
    "slash_commands", "command.request", "command.reply", "slash.command",
    "delivery.send", "cron.delivery", "proactive.delivery", "cron_delivery",
    "proactive_delivery", "sessions", "artifacts",
})
KNOWN_CAPABILITIES = SUPPORTED_CAPABILITIES | HELPER_CAPABILITIES
LEGACY_CAPABILITIES = frozenset({"messages", "attachments", "ack", "reconnect", "device_auth"})
KNOWN_TYPES = frozenset({
    "hello", "hello_ack", "ping", "pong", "message.send", "message.reply", "message.ack", "agent.ack", "error",
    "capabilities.hello", "capabilities.ack",
    "typing", "typing.start", "typing.stop", "stream.start", "stream.delta", "stream.end",
    "agent.state", "tool.state", "clarify.request", "clarify.response", "approval.request", "approval.response",
    "agent.typing", "agent.start", "agent.started", "agent.delta", "agent.complete", "agent.completed",
    "agent.error", "agent.failed", "agent.status", "tool.started", "tool.progress", "tool.completed", "tool.failed",
    "clarify.resolve", "clarify.cancel", "approval.resolve", "session.start", "session.started", "session.created",
    "session.update", "session.complete", "session.completed", "session.cancel", "session.cancelled", "session.error",
    "session.failed", "artifact.started", "artifact.created", "artifact.progress", "artifact.completed", "artifact.failed",
    "command.request", "command.reply", "slash.command", "slash.reply", "delivery.send", "delivery.ack",
    "cron.delivery", "proactive.delivery", "session.open", "session.close", "session.reset", "session.list",
    "session.info", "session.reply", "artifact", "artifact.event",
})

MAX_ATTACHMENTS = 16
MAX_ATTACHMENT_NAME = 180
MAX_CHOICES = 32
MAX_CAPABILITIES = 64
MAX_EVENT_TEXT = 256 * 1024
_EXCLUDED_ATTACHMENT_PREFIXES = ("audio/", "video/")
_ALLOWED_APPROVAL_CHOICES = frozenset({"once", "session", "always", "deny"})
_ALLOWED_SLASH_CHOICES = frozenset({"once", "always", "cancel"})
_ALLOWED_APPROVAL_DECISIONS = frozenset({"once", "session", "always", "deny", "timeout", "cancelled"})
_ALLOWED_AGENT_ACK_STATUSES = frozenset({"received", "duplicate", "gap", "unknown"})
_ALLOWED_TYPING_STATES = frozenset({"start", "stop", "started", "stopped"})
ATTACHMENT_METADATA_FIELDS = frozenset({"id", "name", "mime_type", "size", "download_url"})

DOMAIN_CONTRACTS = {
    "task": (
        "id", "title", "notes", "important", "urgent", "completed", "completedAt",
        "due", "dueTime", "reminderMinutes", "projectId", "recurrence", "createdAt",
        "updatedAt", "version", "deletedAt",
    ),
    "schedule": (
        "id", "title", "description", "location", "startAt", "endAt", "allDay",
        "reminderMinutes", "createdAt", "updatedAt", "version", "deletedAt",
    ),
    "conversation": ("id", "title", "createdAt", "updatedAt"),
}

_DATE_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_LOCAL_TIME_PATTERN = re.compile(r"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$")
_RRULE_FREQUENCY_PATTERN = re.compile(r"(?:^|;)FREQ=[A-Z]+(?:;|$)")


class ProtocolError(ValueError):
    """A malformed or unsupported Agent Gateway frame."""

    def __init__(self, message: str, *, code: str = "INVALID_MESSAGE") -> None:
        super().__init__(message)
        self.code = code


def is_valid_agent_device_id(value: str) -> bool:
    """Validate the stable ``<USER>_<DEVICE>_<Agent>`` naming convention."""
    parts = value.split("_")
    if len(parts) != 3 or len(value) > 80:
        return False
    owner, device, agent = parts
    return (
        2 <= len(owner) <= 24 and 2 <= len(device) <= 24 and 2 <= len(agent) <= 24
        and owner.isascii() and device.isascii() and agent.isascii()
        and owner.isalnum() and device.isalnum() and agent.isalnum()
    )


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


def _optional_text(message: Mapping[str, Any], field: str) -> None:
    value = message.get(field)
    if value is not None and (not isinstance(value, str) or len(value) > MAX_EVENT_TEXT):
        raise ProtocolError(f"{field} must be a string")


def _non_negative_int(message: Mapping[str, Any], field: str, *, optional: bool = False) -> None:
    value = message.get(field)
    if value is None and optional:
        return
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolError(f"{field} must be a non-negative integer")


def _positive_number(message: Mapping[str, Any], field: str, *, optional: bool = False) -> None:
    value = message.get(field)
    if value is None and optional:
        return
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        raise ProtocolError(f"{field} must be a positive number")


def _text_list(value: Any, field: str, *, max_items: int) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > max_items:
        raise ProtocolError(f"{field} must be an array of at most {max_items} strings")
    result = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise ProtocolError(f"{field} must contain non-empty strings")
        result.append(item)
    return result


def _normalize_attachment(item: Mapping[str, Any]) -> dict[str, Any]:
    """Normalize Server API camelCase metadata to the Gateway wire shape."""
    attachment = dict(item)
    if "mime_type" not in attachment and "mimeType" in attachment:
        attachment["mime_type"] = attachment.pop("mimeType")
    if "download_url" not in attachment and "downloadUrl" in attachment:
        attachment["download_url"] = attachment.pop("downloadUrl")
    return attachment


def _validate_attachments(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > MAX_ATTACHMENTS:
        raise ProtocolError("attachments must be an array of at most 16 items")
    result: list[dict[str, Any]] = []
    for item in value:
        if not isinstance(item, Mapping):
            raise ProtocolError("each attachment must be an object")
        attachment = _normalize_attachment(item)
        unexpected = set(attachment) - ATTACHMENT_METADATA_FIELDS
        if unexpected:
            raise ProtocolError("attachments carry metadata only; unsupported fields: " + ", ".join(sorted(unexpected)))
        for field in ("id", "name", "mime_type", "download_url"):
            _required_text(attachment, field)
        mime = attachment["mime_type"].lower().split(";", 1)[0].strip()
        if mime.startswith(_EXCLUDED_ATTACHMENT_PREFIXES):
            raise ProtocolError("audio, voice, and video attachments are not supported")
        if not (mime.startswith("image/") or mime.startswith("text/") or mime in {
            "application/pdf", "application/json", "application/xml", "application/octet-stream", "application/zip",
        }):
            raise ProtocolError(f"unsupported attachment MIME type {mime}")
        size = attachment.get("size")
        if size is not None and (isinstance(size, bool) or not isinstance(size, int) or size < 1):
            raise ProtocolError("attachment size must be a positive integer")
        if len(attachment["name"]) > MAX_ATTACHMENT_NAME:
            raise ProtocolError("attachment name is too long")
        result.append(attachment)
    return result


def _domain_timestamp(value: Any, field: str, *, nullable: bool = False) -> Optional[datetime]:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ProtocolError(f"{field} must be an RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ProtocolError(f"{field} must be an RFC 3339 timestamp") from exc
    if parsed.tzinfo is None:
        raise ProtocolError(f"{field} must include a timezone")
    return parsed


def _nullable_string(value: Any, field: str) -> None:
    if value is not None and (not isinstance(value, str)):
        raise ProtocolError(f"{field} must be a string or null")


def _nullable_boolean(value: Any, field: str) -> None:
    if value is not None and not isinstance(value, bool):
        raise ProtocolError(f"{field} must be a boolean or null")


def _nullable_non_negative_integer(value: Any, field: str) -> None:
    if value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
        raise ProtocolError(f"{field} must be a non-negative integer or null")


def _nullable_date(value: Any, field: str) -> None:
    if value is None:
        return
    if not isinstance(value, str) or not _DATE_PATTERN.fullmatch(value):
        raise ProtocolError(f"{field} must be a YYYY-MM-DD date or null")
    try:
        date.fromisoformat(value)
    except ValueError as exc:
        raise ProtocolError(f"{field} must be a valid YYYY-MM-DD date or null") from exc


def _validate_recurrence(value: Any) -> None:
    if value is None:
        return
    if not isinstance(value, Mapping) or set(value) != {"rule", "until"}:
        raise ProtocolError("recurrence must be null or an object with rule and until")
    rule, until = value["rule"], value["until"]
    if not isinstance(rule, str) or not rule.strip() or not _RRULE_FREQUENCY_PATTERN.search(rule):
        raise ProtocolError("recurrence.rule must be a non-empty RFC 5545 RRULE string")
    _nullable_date(until, "recurrence.until")


def _validate_task_record(record: Mapping[str, Any]) -> None:
    if not isinstance(record.get("title"), str) or not record["title"].strip():
        raise ProtocolError("task.title is required")
    for field in ("important", "urgent"):
        _nullable_boolean(record[field], f"task.{field}")
    if not isinstance(record["completed"], bool):
        raise ProtocolError("task.completed must be a boolean")
    _nullable_string(record["notes"], "task.notes")
    _domain_timestamp(record["completedAt"], "task.completedAt", nullable=True)
    if record["completed"] and record["completedAt"] is None:
        raise ProtocolError("task.completedAt is required when task.completed is true")
    if not record["completed"] and record["completedAt"] is not None:
        raise ProtocolError("task.completedAt must be null when task.completed is false")
    due = record["due"]
    _nullable_date(due, "task.due")
    due_time = record["dueTime"]
    if due_time is not None and (not isinstance(due_time, str) or not _LOCAL_TIME_PATTERN.fullmatch(due_time)):
        raise ProtocolError("task.dueTime must be an HH:MM local time or null")
    if due is None and due_time is not None:
        raise ProtocolError("task.dueTime requires task.due")
    _nullable_non_negative_integer(record["reminderMinutes"], "task.reminderMinutes")
    _nullable_string(record["projectId"], "task.projectId")
    _validate_recurrence(record["recurrence"])


def validate_domain_record(kind: str, record: Mapping[str, Any]) -> dict[str, Any]:
    """Validate the shared v1 Task/Schedule shape without creating domain entities."""
    if kind not in DOMAIN_CONTRACTS:
        raise ProtocolError(f"unsupported domain kind {kind}", code="UNKNOWN_DOMAIN")
    if not isinstance(record, Mapping):
        raise ProtocolError(f"{kind} must be an object")
    normalized = dict(record)
    missing = set(DOMAIN_CONTRACTS[kind]) - set(normalized)
    if missing:
        raise ProtocolError(f"{kind}.{sorted(missing)[0]} is required")
    unexpected = set(normalized) - set(DOMAIN_CONTRACTS[kind])
    if unexpected:
        raise ProtocolError(f"{kind} has unsupported fields: {', '.join(sorted(unexpected))}")
    for field in DOMAIN_CONTRACTS[kind]:
        value = normalized.get(field)
        if field == "version":
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise ProtocolError(f"{kind}.{field} must be a positive integer")
        elif field in {"createdAt", "updatedAt"}:
            _domain_timestamp(value, f"{kind}.{field}")
        elif field == "deletedAt":
            _domain_timestamp(value, f"{kind}.{field}", nullable=True)
        elif field == "id":
            if not isinstance(value, str) or not value.strip():
                raise ProtocolError(f"{kind}.{field} is required")
        elif kind == "schedule" and field in {"startAt", "endAt"}:
            _domain_timestamp(value, f"schedule.{field}")
        elif kind == "schedule" and field in {"description", "location"}:
            _nullable_string(value, f"schedule.{field}")
        elif kind == "schedule" and field == "allDay":
            if not isinstance(value, bool):
                raise ProtocolError("schedule.allDay must be a boolean")
        elif kind == "schedule" and field == "reminderMinutes":
            _nullable_non_negative_integer(value, "schedule.reminderMinutes")
        elif kind == "task" and field not in {"id", "title", "createdAt", "updatedAt", "version"}:
            # Task-specific nullable and boolean invariants are checked together below.
            continue
        elif kind == "conversation" and field == "title":
            if not isinstance(value, str) or not value.strip():
                raise ProtocolError(f"{kind}.{field} is required")
        elif not isinstance(value, str) or not value.strip():
            raise ProtocolError(f"{kind}.{field} is required")
    if kind == "task":
        _validate_task_record(normalized)
    elif kind == "schedule":
        start_at = _domain_timestamp(normalized["startAt"], "schedule.startAt")
        end_at = _domain_timestamp(normalized["endAt"], "schedule.endAt")
        if start_at >= end_at:
            raise ProtocolError("schedule.startAt must be earlier than schedule.endAt")
    return normalized


def _has_content_or_attachments(message: Mapping[str, Any]) -> bool:
    content = message.get("content")
    return (isinstance(content, str) and bool(content.strip())) or bool(message.get("attachments"))


def _validate_common_event(message: Mapping[str, Any], *, request: bool = False) -> None:
    _required_text(message, "conversation_id")
    if request:
        _required_text(message, "request_id")
    for field in ("session_key", "session_id", "run_id", "message_id", "reply_to", "delivery_id"):
        _optional_text(message, field)


def _validate_event(message: dict[str, Any]) -> None:
    message_type = message["type"]
    if message_type in {
        "agent.typing", "agent.start", "agent.started", "agent.delta", "agent.complete", "agent.completed",
        "agent.error", "agent.failed", "agent.status", "tool.started", "tool.progress", "tool.completed",
        "tool.failed", "clarify.resolve", "clarify.cancel", "approval.resolve", "session.start",
        "session.started", "session.created", "session.update", "session.complete", "session.completed",
        "session.cancel", "session.cancelled", "session.error", "session.failed", "artifact.started",
        "artifact.created", "artifact.progress", "artifact.completed", "artifact.failed",
    }:
        _validate_structured_event(message)
        return
    if message_type in {"typing.start", "typing.stop"}:
        message.setdefault("state", "start" if message_type.endswith("start") else "stop")
        message["type"] = "typing"
        message_type = "typing"
    if message_type == "typing":
        _validate_common_event(message)
        if message.get("state") not in _ALLOWED_TYPING_STATES:
            raise ProtocolError("typing.state must be start or stop")
        return
    if message_type == "stream.start":
        _validate_common_event(message)
        _required_text(message, "stream_id")
        return
    if message_type == "stream.delta":
        _required_text(message, "stream_id")
        if not isinstance(message.get("delta"), str) or len(message["delta"]) > MAX_EVENT_TEXT:
            raise ProtocolError("stream.delta must be a string")
        _non_negative_int(message, "sequence")
        _optional_text(message, "conversation_id")
        return
    if message_type == "stream.end":
        _required_text(message, "stream_id")
        _optional_text(message, "conversation_id")
        _non_negative_int(message, "sequence", optional=True)
        if message.get("status", "completed") not in {"completed", "cancelled", "failed"}:
            raise ProtocolError("stream.end.status is invalid")
        return
    if message_type in {"agent.state", "tool.state"}:
        _validate_common_event(message)
        _required_text(message, "state")
        if message_type == "tool.state":
            _required_text(message, "tool_call_id")
            _optional_text(message, "tool_name")
        _optional_text(message, "message")
        return
    if message_type in {"clarify.request", "approval.request", "command.request", "slash.command"}:
        _validate_common_event(message, request=True)
        if message_type == "clarify.request":
            _required_text(message, "question")
            message["choices"] = _text_list(message.get("choices"), "choices", max_items=MAX_CHOICES) or None
            if "multi_select" in message and not isinstance(message["multi_select"], bool):
                raise ProtocolError("multi_select must be boolean")
        elif message_type == "approval.request":
            _required_text(message, "command")
            _required_text(message, "description")
            choices = _text_list(message.get("choices"), "choices", max_items=8)
            if choices and not set(choices) <= _ALLOWED_APPROVAL_CHOICES:
                raise ProtocolError("approval choices contain an unsupported value")
            _positive_number(message, "timeout_seconds", optional=True)
        else:
            _required_text(message, "command")
            _optional_text(message, "args")
        return
    if message_type in {"clarify.response", "approval.response", "slash.reply", "command.reply", "session.reply", "delivery.ack"}:
        field = "delivery_id" if message_type == "delivery.ack" else "request_id"
        _required_text(message, field)
        _optional_text(message, "conversation_id")
        _optional_text(message, "reason")
        if message_type == "clarify.response":
            _required_text(message, "response")
        elif message_type == "approval.response":
            if _required_text(message, "choice") not in _ALLOWED_APPROVAL_CHOICES:
                raise ProtocolError("approval choice is invalid")
        elif message_type == "slash.reply":
            if _required_text(message, "choice") not in _ALLOWED_SLASH_CHOICES:
                raise ProtocolError("slash choice is invalid")
        elif message_type == "command.reply":
            _required_text(message, "status")
            _optional_text(message, "content")
        elif message_type == "session.reply":
            _required_text(message, "status")
        else:
            _required_text(message, "status")
        return
    if message_type in {"delivery.send", "cron.delivery", "proactive.delivery"}:
        _required_text(message, "delivery_id")
        _required_text(message, "conversation_id")
        if "attachments" in message:
            message["attachments"] = _validate_attachments(message["attachments"])
        if not _has_content_or_attachments(message):
            raise ProtocolError("content or attachments is required")
        return
    if message_type in {"session.open", "session.close", "session.reset", "session.list", "session.info"}:
        _required_text(message, "request_id")
        if message_type == "session.open":
            _required_text(message, "conversation_id")
        elif message_type != "session.list":
            _required_text(message, "session_id")
        return
    if message_type in {"artifact", "artifact.event"}:
        _required_text(message, "artifact_id")
        _required_text(message, "conversation_id")
        _required_text(message, "name")
        mime = _required_text(message, "mime_type").lower().split(";", 1)[0].strip()
        if mime.startswith(_EXCLUDED_ATTACHMENT_PREFIXES):
            raise ProtocolError("audio, voice, and video artifacts are not supported")
        if not (mime.startswith("image/") or mime.startswith("text/") or mime in {
            "application/pdf", "application/json", "application/xml", "application/octet-stream", "application/zip",
        }):
            raise ProtocolError(f"unsupported artifact MIME type {mime}")
        if not any(isinstance(message.get(field), str) and message[field].strip() for field in ("url", "download_url", "content")):
            raise ProtocolError("artifact requires url, download_url, or content")
        _non_negative_int(message, "size", optional=True)
        return


def _validate_structured_event(message: Mapping[str, Any]) -> None:
    """Validate the event-v1 schema used by the Rust transport layer."""
    _required_text(message, "event_id")
    _required_text(message, "session_id")
    value = message.get("seq")
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise ProtocolError("seq must be a positive integer")
    for field in ("run_id", "request_id", "conversation_id", "reply_to", "stream_id", "tool_call_id", "artifact_id"):
        _optional_text(message, field)
    message_type = message["type"]
    if message_type == "agent.typing":
        if not isinstance(message.get("typing"), bool):
            raise ProtocolError("agent.typing.typing must be boolean")
    elif message_type in {"agent.start", "agent.started", "agent.delta", "agent.complete", "agent.completed", "agent.error", "agent.failed"}:
        _required_text(message, "run_id")
        if message_type == "agent.delta":
            if not isinstance(message.get("delta"), str) or len(message["delta"]) > MAX_EVENT_TEXT:
                raise ProtocolError("agent.delta must be a string")
        if message_type in {"agent.error", "agent.failed"}:
            _required_text(message, "code")
            if not isinstance(message.get("message"), str):
                raise ProtocolError("agent error message must be a string")
    elif message_type == "agent.status":
        _required_text(message, "status")
    elif message_type == "tool.started":
        _required_text(message, "tool_call_id")
        _required_text(message, "tool_name")
    elif message_type in {"tool.progress", "tool.completed"}:
        _required_text(message, "tool_call_id")
    elif message_type == "tool.failed":
        _required_text(message, "tool_call_id")
        _required_text(message, "code")
        _required_text(message, "message")
    elif message_type == "clarify.request":
        _required_text(message, "request_id")
        _required_text(message, "question")
        _text_list(message.get("choices"), "choices", max_items=MAX_CHOICES)
        if "multi_select" in message and not isinstance(message["multi_select"], bool):
            raise ProtocolError("multi_select must be boolean")
    elif message_type in {"clarify.resolve", "clarify.cancel"}:
        _required_text(message, "request_id")
    elif message_type == "approval.request":
        _required_text(message, "request_id")
        _required_text(message, "action")
    elif message_type == "approval.resolve":
        _required_text(message, "request_id")
        if message.get("decision") not in _ALLOWED_APPROVAL_DECISIONS:
            raise ProtocolError("approval decision is invalid")
    elif message_type == "session.update":
        if not isinstance(message.get("update"), Mapping):
            raise ProtocolError("session.update.update must be an object")
    elif message_type == "session.error":
        _required_text(message, "code")
        _required_text(message, "message")
    elif message_type in {"artifact.started", "artifact.created", "artifact.completed"}:
        artifact = message.get("artifact")
        if not isinstance(artifact, Mapping):
            raise ProtocolError("artifact lifecycle event requires an artifact object")
        _required_text(artifact, "id")
        kind = _required_text(artifact, "kind")
        mime = str(artifact.get("mime_type", "")).lower().split(";", 1)[0].strip()
        if mime.startswith(_EXCLUDED_ATTACHMENT_PREFIXES) or kind.lower() in {"audio", "video", "voice"}:
            raise ProtocolError("audio, voice, and video artifacts are not supported")
    elif message_type == "artifact.progress":
        _required_text(message, "artifact_id")
        if "progress" not in message:
            raise ProtocolError("artifact.progress requires progress")
    elif message_type == "artifact.failed":
        _required_text(message, "artifact_id")
        _required_text(message, "code")
        _required_text(message, "message")


def parse_message(raw: Any) -> dict[str, Any]:
    """Parse one frame, returning a normalized dictionary."""
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
        if not is_valid_agent_device_id(message["device_id"]):
            raise ProtocolError("device_id must use <USER>_<DEVICE>_<Agent> format", code="INVALID_DEVICE_ID")
        message["capabilities"] = _text_list(message.get("capabilities"), "capabilities", max_items=MAX_CAPABILITIES)
    elif message_type == "hello_ack":
        message["capabilities"] = _text_list(message.get("capabilities", message.get("features")), "capabilities", max_items=MAX_CAPABILITIES)
    elif message_type in {"capabilities.hello", "capabilities.ack"}:
        message["capabilities"] = _text_list(message.get("capabilities"), "capabilities", max_items=MAX_CAPABILITIES)
        _non_negative_int(message, "resume_from", optional=True)
        _non_negative_int(message, "next_seq", optional=True)
    elif message_type == "message.send":
        for field in ("message_id", "conversation_id"):
            _required_text(message, field)
        if "attachments" in message:
            message["attachments"] = _validate_attachments(message["attachments"])
        if not _has_content_or_attachments(message):
            raise ProtocolError("content or attachments is required")
    elif message_type == "message.reply":
        for field in ("message_id", "reply_to", "conversation_id"):
            _required_text(message, field)
        if "attachments" in message:
            message["attachments"] = _validate_attachments(message["attachments"])
        if not _has_content_or_attachments(message):
            raise ProtocolError("content or attachments is required")
    elif message_type == "message.ack":
        for field in ("message_id", "status"):
            _required_text(message, field)
    elif message_type == "agent.ack":
        for field in ("event_id", "status"):
            _required_text(message, field)
        if message["status"] not in _ALLOWED_AGENT_ACK_STATUSES:
            raise ProtocolError("agent.ack.status is invalid")
        _non_negative_int(message, "seq")
        if message["seq"] < 1:
            raise ProtocolError("agent.ack.seq must be a positive integer")
        _non_negative_int(message, "expected_seq", optional=True)
        if message["status"] == "gap" and (
            not isinstance(message.get("expected_seq"), int)
            or isinstance(message["expected_seq"], bool)
            or message["expected_seq"] < 1
        ):
            raise ProtocolError("agent.ack gap requires a positive expected_seq")
    elif message_type == "error":
        for field in ("code", "message"):
            _required_text(message, field)
        if message.get("reply_to") is not None:
            _required_text(message, "reply_to")
    else:
        _validate_event(message)
    return message


def encode(message: Mapping[str, Any]) -> str:
    parsed = parse_message(message)
    return json.dumps(parsed, ensure_ascii=False, separators=(",", ":"))


def capabilities_from_ack(message: Mapping[str, Any]) -> set[str]:
    values = message.get("capabilities") or message.get("features") or []
    return {str(value) for value in values if str(value) in KNOWN_CAPABILITIES}


def hello(device_id: str, plugin_version: str = "1.0.0", platform: str = "macos", capabilities: Optional[Sequence[str]] = None) -> dict[str, Any]:
    return {
        "version": PROTOCOL_VERSION, "type": "hello", "device_id": device_id,
        "client": "orialis-hermes-plugin", "plugin_version": plugin_version, "platform": platform,
        "capabilities": list(capabilities if capabilities is not None else sorted(SUPPORTED_CAPABILITIES)),
    }


def hello_ack(capabilities: Optional[Sequence[str]] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"version": PROTOCOL_VERSION, "type": "hello_ack"}
    if capabilities is not None:
        payload["capabilities"] = list(capabilities)
    return payload


def capabilities_hello(capabilities: Optional[Sequence[str]] = None, *, resume_from: Optional[int] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "version": PROTOCOL_VERSION, "type": "capabilities.hello",
        "capabilities": list(capabilities if capabilities is not None else sorted(SUPPORTED_CAPABILITIES)),
    }
    if resume_from is not None:
        payload["resume_from"] = resume_from
    return payload


def capabilities_ack(capabilities: Sequence[str], *, resume_from: Optional[int] = None, next_seq: Optional[int] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "version": PROTOCOL_VERSION, "type": "capabilities.ack", "capabilities": list(capabilities),
    }
    if resume_from is not None:
        payload["resume_from"] = resume_from
    if next_seq is not None:
        payload["next_seq"] = next_seq
    return payload

def ping() -> dict[str, Any]:
    return {"version": PROTOCOL_VERSION, "type": "ping"}


def pong() -> dict[str, Any]:
    return {"version": PROTOCOL_VERSION, "type": "pong"}


def ack(message_id: str, status: str = "received") -> dict[str, Any]:
    return {"version": PROTOCOL_VERSION, "type": "message.ack", "message_id": message_id, "status": status}


def reply(*, message_id: str, reply_to: str, conversation_id: str, content: str, attachments: Optional[Sequence[Mapping[str, Any]]] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "version": PROTOCOL_VERSION, "type": "message.reply", "message_id": message_id,
        "reply_to": reply_to, "conversation_id": conversation_id, "content": content,
    }
    if attachments:
        payload["attachments"] = [_normalize_attachment(item) for item in attachments]
    return payload


def error(code: str, message: str, reply_to: Optional[str] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"version": PROTOCOL_VERSION, "type": "error", "code": code, "message": message}
    if reply_to:
        payload["reply_to"] = reply_to
    return payload


def typing(*, conversation_id: str, state: str, message_id: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "typing", "conversation_id": conversation_id, "state": state}
    if message_id:
        payload["message_id"] = message_id
    return payload


def stream_start(*, stream_id: str, conversation_id: str, reply_to: Optional[str] = None, run_id: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "stream.start", "stream_id": stream_id, "conversation_id": conversation_id}
    if reply_to:
        payload["reply_to"] = reply_to
    if run_id:
        payload["run_id"] = run_id
    return payload


def stream_delta(*, stream_id: str, delta: str, sequence: int, conversation_id: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "stream.delta", "stream_id": stream_id, "delta": delta, "sequence": sequence}
    if conversation_id:
        payload["conversation_id"] = conversation_id
    return payload


def stream_end(*, stream_id: str, status: str = "completed", sequence: Optional[int] = None, conversation_id: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "stream.end", "stream_id": stream_id, "status": status}
    if sequence is not None:
        payload["sequence"] = sequence
    if conversation_id:
        payload["conversation_id"] = conversation_id
    return payload


def agent_state(*, conversation_id: str, state: str, run_id: Optional[str] = None, message: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "agent.state", "conversation_id": conversation_id, "state": state}
    if run_id:
        payload["run_id"] = run_id
    if message is not None:
        payload["message"] = message
    return payload


def tool_state(*, conversation_id: str, tool_call_id: str, state: str, tool_name: Optional[str] = None, run_id: Optional[str] = None, data: Any = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "tool.state", "conversation_id": conversation_id, "tool_call_id": tool_call_id, "state": state}
    if tool_name:
        payload["tool_name"] = tool_name
    if run_id:
        payload["run_id"] = run_id
    if data is not None:
        payload["data"] = data
    return payload


def clarify_request(*, request_id: str, conversation_id: str, question: str, choices: Optional[Sequence[str]], session_key: str, multi_select: bool = False, reply_to: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "clarify.request", "request_id": request_id, "conversation_id": conversation_id, "question": question, "choices": list(choices) if choices else None, "session_key": session_key, "multi_select": bool(multi_select)}
    if reply_to:
        payload["reply_to"] = reply_to
    return payload


def clarify_response(*, request_id: str, conversation_id: str, response: str, reason: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "clarify.response", "request_id": request_id, "conversation_id": conversation_id, "response": response}
    if reason:
        payload["reason"] = reason
    return payload


def approval_request(*, request_id: str, conversation_id: str, session_key: str, command: str, description: str, choices: Sequence[str], timeout_seconds: float, reply_to: Optional[str] = None, smart_denied: bool = False) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "approval.request", "request_id": request_id, "conversation_id": conversation_id, "session_key": session_key, "command": command, "description": description, "choices": list(choices), "timeout_seconds": timeout_seconds, "smart_denied": bool(smart_denied)}
    if reply_to:
        payload["reply_to"] = reply_to
    return payload


def approval_response(*, request_id: str, conversation_id: str, choice: str, reason: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "approval.response", "request_id": request_id, "conversation_id": conversation_id, "choice": choice}
    if reason:
        payload["reason"] = reason
    return payload


def command_request(*, request_id: str, conversation_id: str, command: str, args: str = "", session_key: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "command.request", "request_id": request_id, "conversation_id": conversation_id, "command": command, "args": args}
    if session_key:
        payload["session_key"] = session_key
    return payload


def slash_command(*, request_id: str, conversation_id: str, command: str, args: str = "", session_key: Optional[str] = None) -> dict[str, Any]:
    payload = command_request(
        request_id=request_id, conversation_id=conversation_id, command=command,
        args=args, session_key=session_key,
    )
    payload["type"] = "slash.command"
    return payload


def command_reply(*, request_id: str, conversation_id: str, status: str = "completed", content: Optional[str] = None) -> dict[str, Any]:
    payload = {"version": PROTOCOL_VERSION, "type": "command.reply", "request_id": request_id, "conversation_id": conversation_id, "status": status}
    if content is not None:
        payload["content"] = content
    return payload


def delivery(*, delivery_id: str, conversation_id: str, content: str, kind: str = "delivery.send", metadata: Optional[Mapping[str, Any]] = None, attachments: Optional[Sequence[Mapping[str, Any]]] = None) -> dict[str, Any]:
    if kind not in {"delivery.send", "cron.delivery", "proactive.delivery"}:
        raise ValueError("invalid delivery kind")
    payload: dict[str, Any] = {"version": PROTOCOL_VERSION, "type": kind, "delivery_id": delivery_id, "conversation_id": conversation_id, "content": content}
    if metadata:
        payload["metadata"] = dict(metadata)
    if attachments:
        payload["attachments"] = [_normalize_attachment(item) for item in attachments]
    return payload


def session_request(*, action: str, request_id: str, session_id: Optional[str] = None, conversation_id: Optional[str] = None, data: Optional[Mapping[str, Any]] = None) -> dict[str, Any]:
    if action not in {"open", "close", "reset", "list", "info"}:
        raise ValueError("invalid session action")
    payload: dict[str, Any] = {"version": PROTOCOL_VERSION, "type": f"session.{action}", "request_id": request_id}
    if session_id:
        payload["session_id"] = session_id
    if conversation_id:
        payload["conversation_id"] = conversation_id
    if data:
        payload["data"] = dict(data)
    return payload


def artifact(*, artifact_id: str, conversation_id: str, name: str, mime_type: str, url: Optional[str] = None, download_url: Optional[str] = None, content: Optional[str] = None, size: Optional[int] = None, metadata: Optional[Mapping[str, Any]] = None) -> dict[str, Any]:
    payload: dict[str, Any] = {"version": PROTOCOL_VERSION, "type": "artifact", "artifact_id": artifact_id, "conversation_id": conversation_id, "name": name, "mime_type": mime_type}
    if url:
        payload["url"] = url
    if download_url:
        payload["download_url"] = download_url
    if content is not None:
        payload["content"] = content
    if size is not None:
        payload["size"] = size
    if metadata:
        payload["metadata"] = dict(metadata)
    return payload


def _event(type_name: str, *, event_id: Optional[str] = None, seq: int = 1, session_id: str = "session_default", **fields: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "version": PROTOCOL_VERSION, "type": type_name,
        "event_id": event_id or f"evt_{uuid.uuid4().hex[:16]}", "seq": seq,
        "session_id": session_id,
    }
    payload.update({key: value for key, value in fields.items() if value is not None})
    return payload


def agent_typing(*, conversation_id: str, typing: bool, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, run_id: Optional[str] = None) -> dict[str, Any]:
    return _event("agent.typing", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, typing=bool(typing), run_id=run_id)


def agent_start(*, conversation_id: str, run_id: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, status: Optional[str] = None, stream_id: Optional[str] = None) -> dict[str, Any]:
    return _event("agent.start", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, run_id=run_id, status=status, stream_id=stream_id)


def agent_delta(*, conversation_id: str, run_id: str, delta: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, stream_id: Optional[str] = None) -> dict[str, Any]:
    return _event("agent.delta", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, run_id=run_id, delta=delta, stream_id=stream_id)


def agent_complete(*, conversation_id: str, run_id: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, result: Any = None) -> dict[str, Any]:
    return _event("agent.complete", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, run_id=run_id, result=result)


def agent_error(*, conversation_id: str, run_id: str, code: str, message: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None) -> dict[str, Any]:
    return _event("agent.error", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, run_id=run_id, code=code, message=message)


def agent_status(*, conversation_id: str, status: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, run_id: Optional[str] = None, message: Optional[str] = None) -> dict[str, Any]:
    return _event("agent.status", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, status=status, run_id=run_id, message=message)


def tool_event(*, event_type: str, conversation_id: str, tool_call_id: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, run_id: Optional[str] = None, tool_name: Optional[str] = None, progress: Any = None, output: Any = None, code: Optional[str] = None, message: Optional[str] = None) -> dict[str, Any]:
    if event_type not in {"tool.started", "tool.progress", "tool.completed", "tool.failed"}:
        raise ValueError("invalid tool event type")
    return _event(event_type, event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, run_id=run_id, tool_call_id=tool_call_id, tool_name=tool_name, progress=progress, output=output, code=code, message=message)


def clarify_event(*, event_type: str, request_id: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, conversation_id: Optional[str] = None, question: Optional[str] = None, choices: Optional[Sequence[str]] = None, multi_select: Optional[bool] = None, response: Optional[str] = None, reason: Optional[str] = None) -> dict[str, Any]:
    if event_type not in {"clarify.request", "clarify.resolve", "clarify.cancel"}:
        raise ValueError("invalid clarify event type")
    return _event(event_type, event_id=event_id, seq=seq, session_id=session_id, request_id=request_id, conversation_id=conversation_id, question=question, choices=list(choices) if choices else None, multi_select=multi_select, response=response, reason=reason)


def clarify_resolve(*, request_id: str, response: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, conversation_id: Optional[str] = None, reason: Optional[str] = None) -> dict[str, Any]:
    return clarify_event(
        event_type="clarify.resolve", request_id=request_id, response=response,
        session_id=session_id, seq=seq, event_id=event_id, conversation_id=conversation_id, reason=reason,
    )


def clarify_cancel(*, request_id: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, conversation_id: Optional[str] = None, reason: Optional[str] = None) -> dict[str, Any]:
    return clarify_event(
        event_type="clarify.cancel", request_id=request_id, session_id=session_id,
        seq=seq, event_id=event_id, conversation_id=conversation_id, reason=reason,
    )


def approval_event(*, event_type: str, request_id: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, conversation_id: Optional[str] = None, action: Optional[str] = None, decision: Optional[str] = None, reason: Optional[str] = None) -> dict[str, Any]:
    if event_type not in {"approval.request", "approval.resolve"}:
        raise ValueError("invalid approval event type")
    return _event(event_type, event_id=event_id, seq=seq, session_id=session_id, request_id=request_id, conversation_id=conversation_id, action=action, decision=decision, reason=reason)


def approval_resolve(*, request_id: str, decision: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, conversation_id: Optional[str] = None, reason: Optional[str] = None) -> dict[str, Any]:
    return approval_event(
        event_type="approval.resolve", request_id=request_id, decision=decision,
        session_id=session_id, seq=seq, event_id=event_id, conversation_id=conversation_id, reason=reason,
    )


def session_event(*, event_type: str, session_id: str, seq: int = 1, event_id: Optional[str] = None, conversation_id: Optional[str] = None, update: Optional[Mapping[str, Any]] = None, result: Any = None, reason: Optional[str] = None, code: Optional[str] = None, message: Optional[str] = None) -> dict[str, Any]:
    if event_type not in {"session.start", "session.started", "session.created", "session.update", "session.complete", "session.completed", "session.cancel", "session.cancelled", "session.error", "session.failed"}:
        raise ValueError("invalid session event type")
    return _event(event_type, event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, update=dict(update) if update is not None else None, result=result, reason=reason, code=code, message=message)


def artifact_completed(*, artifact_id: str, conversation_id: str, name: str, mime_type: str, session_id: str = "session_default", seq: int = 1, event_id: Optional[str] = None, uri: Optional[str] = None, size: Optional[int] = None, metadata: Optional[Mapping[str, Any]] = None) -> dict[str, Any]:
    artifact_payload: dict[str, Any] = {"id": artifact_id, "kind": "document", "name": name, "mime_type": mime_type}
    if uri:
        artifact_payload["uri"] = uri
    if size is not None:
        artifact_payload["size"] = size
    if metadata:
        artifact_payload["metadata"] = dict(metadata)
    return _event("artifact.completed", event_id=event_id, seq=seq, session_id=session_id, conversation_id=conversation_id, artifact=artifact_payload)
