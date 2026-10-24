#!/usr/bin/env python3
"""Emit new Orialis user messages for a Hermes inbox triage job.

The script keeps a durable acknowledgement watermark. A batch stays pending
until the cron agent acknowledges it, so a failed calendar write is retried on
the next run instead of losing messages.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


MAX_BATCH_MESSAGES = 20
MAX_CONTENT_CHARS = 2500
MAX_PAGES = 50
LOCK_STALE_SECONDS = 10 * 60
STATE_VERSION = 1
UTC = timezone.utc
LOCAL = timezone(timedelta(hours=8))
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0 Safari/537.36"
)


def _profile_home(override: str | None = None) -> Path:
    value = (str(override or "").strip()
             or os.environ.get("ORIALIS_HERMES_PROFILE_HOME", "").strip()
             or os.environ.get("ORIALIS_INBOX_HOME", "").strip())
    if value:
        return Path(value).expanduser().resolve()
    script = Path(__file__).resolve()
    if script.parent.name == "scripts":
        return script.parent.parent
    raise RuntimeError("pass --profile-home or set ORIALIS_HERMES_PROFILE_HOME")


def _state_path(home: Path) -> Path:
    return home / "state" / "orialis-inbox-watch.json"


def _load_profile_env(home: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    env_path = home / ".env"
    if env_path.is_file():
        for raw in env_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip('"').strip("'")
    for key, value in os.environ.items():
        env.setdefault(key, value)
    return env


def _server_root(value: str) -> str:
    value = value.strip()
    if value.startswith("wss://"):
        value = "https://" + value[6:]
    elif value.startswith("ws://"):
        value = "http://" + value[5:]
    value = value.replace("/api/v1/agent/ws", "").rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise RuntimeError("Orialis server URL is invalid")
    return value


def _utc_now() -> datetime:
    return datetime.now(UTC).replace(microsecond=0)


def _iso_utc(value: datetime) -> str:
    return value.astimezone(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")


def _parse_timestamp(value: Any) -> datetime:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("message createdAt is missing")
    parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("message createdAt must include a timezone")
    return parsed.astimezone(UTC)


def _message_key(message: dict[str, Any]) -> tuple[datetime, str]:
    message_id = message.get("id")
    if not isinstance(message_id, str) or not message_id:
        raise ValueError("message id is missing")
    return _parse_timestamp(message.get("createdAt")), message_id


def _watermark_key(watermark: dict[str, Any]) -> tuple[datetime, str]:
    return _parse_timestamp(watermark.get("createdAt")), str(watermark.get("id") or "")


def _atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="\n",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    )
    temp_path = Path(handle.name)
    try:
        with handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def _load_state(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or payload.get("version") != STATE_VERSION:
        raise RuntimeError("unsupported inbox watch state")
    watermark = payload.get("watermark")
    if not isinstance(watermark, dict):
        raise RuntimeError("inbox watch state has no watermark")
    _watermark_key(watermark)
    return payload


class Lock:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.fd: int | None = None

    def __enter__(self) -> "Lock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        for _ in range(2):
            try:
                self.fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(self.fd, f"{os.getpid()} {int(time.time())}\n".encode("ascii"))
                return self
            except FileExistsError:
                try:
                    age = time.time() - self.path.stat().st_mtime
                except FileNotFoundError:
                    continue
                if age <= LOCK_STALE_SECONDS:
                    raise RuntimeError("another Orialis inbox scan is still running")
                try:
                    self.path.unlink()
                except FileNotFoundError:
                    pass
        raise RuntimeError("could not acquire Orialis inbox scan lock")

    def __exit__(self, *_args: Any) -> None:
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        try:
            self.path.unlink()
        except FileNotFoundError:
            pass


class OrialisClient:
    def __init__(self, server: str, token: str) -> None:
        if not token:
            raise RuntimeError("ORIALIS_DEVICE_TOKEN is not configured")
        self.server = server
        self.token = token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def get(self, path: str, query: dict[str, Any] | None = None) -> Any:
        url = self.server + path
        if query:
            url += "?" + urllib.parse.urlencode(
                [(key, str(value)) for key, value in query.items() if value is not None]
            )
        request = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        last_error: Exception | None = None
        for attempt in range(3):
            try:
                with self.opener.open(request, timeout=30) as response:
                    return json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as exc:
                if exc.code in {401, 403}:
                    raise RuntimeError(f"Orialis authentication failed ({exc.code})") from exc
                if exc.code < 500 or attempt == 2:
                    raise RuntimeError(f"Orialis API returned HTTP {exc.code}") from exc
                last_error = exc
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                last_error = exc
                if attempt == 2:
                    raise RuntimeError("Orialis API could not be reached") from exc
            time.sleep(2**attempt)
        raise RuntimeError("Orialis API request failed") from last_error


def _list_conversations(client: OrialisClient) -> list[dict[str, Any]]:
    data = client.get("/api/v1/conversations", {"limit": 100})
    items = data.get("items") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise RuntimeError("Orialis conversations response is invalid")
    conversations = [item for item in items if isinstance(item, dict) and isinstance(item.get("id"), str)]
    cursor = data.get("nextCursor") if isinstance(data, dict) and data.get("hasMore") else None
    pages = 1
    while cursor and pages < MAX_PAGES:
        data = client.get("/api/v1/conversations", {"limit": 100, "after": cursor})
        batch = data.get("items") if isinstance(data, dict) else data
        if not isinstance(batch, list) or not batch:
            break
        conversations.extend(
            item for item in batch if isinstance(item, dict) and isinstance(item.get("id"), str)
        )
        cursor = data.get("nextCursor") if isinstance(data, dict) and data.get("hasMore") else None
        pages += 1
    return conversations


def _list_messages(client: OrialisClient, conversation_id: str) -> list[dict[str, Any]]:
    path = "/api/v1/conversations/" + urllib.parse.quote(conversation_id, safe="") + "/messages"
    cursor: str | None = None
    messages: list[dict[str, Any]] = []
    for _ in range(MAX_PAGES):
        data = client.get(path, {"limit": 500, "after": cursor})
        batch = data.get("items") if isinstance(data, dict) else data
        if not isinstance(batch, list) or not batch:
            break
        messages.extend(item for item in batch if isinstance(item, dict))
        cursor = data.get("nextCursor") if isinstance(data, dict) and data.get("hasMore") else None
        if not cursor:
            break
    return messages


def _collect_new_user_messages(
    client: OrialisClient, watermark: dict[str, Any]
) -> list[dict[str, Any]]:
    threshold = _watermark_key(watermark)
    discovered: list[dict[str, Any]] = []
    for conversation in _list_conversations(client):
        conversation_id = str(conversation["id"])
        title = str(conversation.get("title") or "")[:200]
        for message in _list_messages(client, conversation_id):
            if message.get("role") != "user":
                continue
            try:
                key = _message_key(message)
            except ValueError:
                continue
            if key <= threshold:
                continue
            item = dict(message)
            item["conversationTitle"] = title
            discovered.append(item)
    discovered.sort(key=_message_key)
    return discovered


def _safe_text(value: Any, limit: int) -> str:
    text = str(value or "").replace("\x00", "").strip()
    return text[:limit]


def _message_for_output(message: dict[str, Any]) -> dict[str, Any]:
    attachments = message.get("attachments")
    attachment_names: list[str] = []
    if isinstance(attachments, list):
        for attachment in attachments[:16]:
            if isinstance(attachment, dict):
                name = _safe_text(attachment.get("name"), 180)
                if name:
                    attachment_names.append(name)
    return {
        "id": str(message.get("id") or ""),
        "conversationId": str(message.get("conversationId") or ""),
        "conversationTitle": _safe_text(message.get("conversationTitle"), 200),
        "createdAt": str(message.get("createdAt") or ""),
        "content": _safe_text(message.get("content"), MAX_CONTENT_CHARS),
        "attachmentNames": attachment_names,
    }


def _ack_command(batch_id: str, home: Path) -> str:
    return subprocess.list2cmdline(
        [sys.executable, str(Path(__file__).resolve()), "--profile-home", str(home),
         "ack", "--batch", batch_id]
    )


def _new_pending(batch_id: str, messages: list[dict[str, Any]]) -> dict[str, Any]:
    last = messages[-1]
    return {
        "batchId": batch_id,
        "createdAt": _iso_utc(_utc_now()),
        "messageIds": [str(item["id"]) for item in messages],
        "messages": [_message_for_output(item) for item in messages],
        "highWater": {"createdAt": last["createdAt"], "id": last["id"]},
    }


def _emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))


def _scan(home: Path, state_path: Path) -> int:
    env = _load_profile_env(home)
    state = _load_state(state_path)
    now = _utc_now()
    if state is None:
        watermark = {"createdAt": _iso_utc(now), "id": ""}
        state = {
            "version": STATE_VERSION,
            "initializedAt": _iso_utc(now),
            "updatedAt": _iso_utc(now),
            "lastScanAt": _iso_utc(now),
            "watermark": watermark,
            "pending": None,
            "recentAckedBatches": [],
        }
        _atomic_write_json(state_path, state)
        _emit(
            {
                "status": "initialized",
                "watchedFrom": watermark["createdAt"],
                "message": "Watcher initialized; existing messages were not triaged.",
                "wakeAgent": False,
            }
        )
        return 0

    pending = state.get("pending")
    if isinstance(pending, dict) and pending.get("messages"):
        batch_id = str(pending.get("batchId") or "")
        if not batch_id:
            raise RuntimeError("pending inbox batch is invalid")
        _emit(
            {
                "status": "pending_messages",
                "batchId": batch_id,
                "messageCount": len(pending["messages"]),
                "messages": pending["messages"],
                "ackCommand": _ack_command(batch_id, home),
                "wakeAgent": True,
            }
        )
        return 0

    server = _server_root(
        env.get("ORIALIS_SERVER_URL", "").strip() or "https://orialis.jxcz.top"
    )
    client = OrialisClient(server, env.get("ORIALIS_DEVICE_TOKEN", "").strip())
    discovered = _collect_new_user_messages(client, state["watermark"])
    state["lastScanAt"] = _iso_utc(now)
    state["updatedAt"] = _iso_utc(now)
    if not discovered:
        _atomic_write_json(state_path, state)
        _emit(
            {
                "status": "no_new_messages",
                "scannedAt": state["lastScanAt"],
                "wakeAgent": False,
            }
        )
        return 0

    selected = discovered[:MAX_BATCH_MESSAGES]
    ids_json = json.dumps([str(item["id"]) for item in selected], separators=(",", ":"))
    batch_id = hashlib.sha256(ids_json.encode("utf-8")).hexdigest()[:16]
    pending = _new_pending(batch_id, selected)
    state["pending"] = pending
    _atomic_write_json(state_path, state)
    _emit(
        {
            "status": "new_messages",
            "batchId": batch_id,
            "messageCount": len(pending["messages"]),
            "deferredCount": max(0, len(discovered) - len(selected)),
            "messages": pending["messages"],
            "ackCommand": _ack_command(batch_id, home),
            "wakeAgent": True,
        }
    )
    return 0


def _ack(home: Path, state_path: Path, batch_id: str) -> int:
    del home
    state = _load_state(state_path)
    if state is None:
        raise RuntimeError("inbox watcher is not initialized")
    recent = state.get("recentAckedBatches")
    if isinstance(recent, list) and batch_id in recent:
        _emit({"status": "already_acked", "batchId": batch_id, "acked": True})
        return 0
    pending = state.get("pending")
    if not isinstance(pending, dict):
        raise RuntimeError("there is no pending inbox batch")
    if str(pending.get("batchId") or "") != batch_id:
        raise RuntimeError("batch id does not match the pending inbox batch")
    high_water = pending.get("highWater")
    if not isinstance(high_water, dict):
        raise RuntimeError("pending inbox batch has no high-water mark")
    _message_key(
        {
            "id": high_water.get("id"),
            "createdAt": high_water.get("createdAt"),
        }
    )
    state["watermark"] = high_water
    state["pending"] = None
    state["updatedAt"] = _iso_utc(_utc_now())
    batches = state.get("recentAckedBatches")
    if not isinstance(batches, list):
        batches = []
    batches.append(batch_id)
    state["recentAckedBatches"] = batches[-100:]
    _atomic_write_json(state_path, state)
    _emit(
        {
            "status": "acked",
            "batchId": batch_id,
            "acked": True,
            "watermark": high_water,
        }
    )
    return 0


def _status(state_path: Path) -> int:
    state = _load_state(state_path)
    if state is None:
        _emit({"status": "uninitialized"})
        return 0
    pending = state.get("pending")
    _emit(
        {
            "status": "ok",
            "initializedAt": state.get("initializedAt"),
            "updatedAt": state.get("updatedAt"),
            "lastScanAt": state.get("lastScanAt"),
            "watermark": state.get("watermark"),
            "pendingBatchId": pending.get("batchId") if isinstance(pending, dict) else None,
            "pendingMessageCount": len(pending.get("messages") or []) if isinstance(pending, dict) else 0,
        }
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-home", help="Hermes profile directory; defaults to the installed scripts/ parent")
    subparsers = parser.add_subparsers(dest="command")
    ack_parser = subparsers.add_parser("ack")
    ack_parser.add_argument("--batch", required=True)
    subparsers.add_parser("status")
    args = parser.parse_args(argv)

    try:
        home = _profile_home(args.profile_home)
        state_path = _state_path(home)
        lock_path = state_path.with_suffix(".lock")
        with Lock(lock_path):
            if args.command == "ack":
                return _ack(home, state_path, args.batch.strip())
            if args.command == "status":
                return _status(state_path)
            return _scan(home, state_path)
    except Exception as exc:  # noqa: BLE001
        print(f"Orialis inbox watch failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
