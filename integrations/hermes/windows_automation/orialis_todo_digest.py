#!/usr/bin/env python3
"""Render a concise Orialis task and calendar digest for Hermes delivery."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


LOCAL = timezone(timedelta(hours=8))
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/126.0 Safari/537.36"
)
MAX_PAGES = 10


def _profile_home(override: str | None = None) -> Path:
    value = (str(override or "").strip()
             or os.environ.get("ORIALIS_HERMES_PROFILE_HOME", "").strip()
             or os.environ.get("ORIALIS_DIGEST_HOME", "").strip())
    if value:
        return Path(value).expanduser().resolve()
    script = Path(__file__).resolve()
    if script.parent.name == "scripts":
        return script.parent.parent
    raise RuntimeError("pass --profile-home or set ORIALIS_HERMES_PROFILE_HOME")


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


def _now() -> datetime:
    override = os.environ.get("ORIALIS_DIGEST_NOW", "").strip()
    if override:
        parsed = datetime.fromisoformat(override.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=LOCAL)
        return parsed.astimezone(LOCAL)
    return datetime.now(LOCAL)


class Client:
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
        try:
            with self.opener.open(request, timeout=30) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code in {401, 403}:
                raise RuntimeError(f"Orialis authentication failed ({exc.code})") from exc
            raise RuntimeError(f"Orialis API returned HTTP {exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RuntimeError("Orialis API could not be reached") from exc

    def list_all(self, path: str) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        cursor: str | None = None
        for _ in range(MAX_PAGES):
            data = self.get(path, {"limit": 100, "after": cursor})
            batch = data.get("items") if isinstance(data, dict) else data
            if not isinstance(batch, list) or not batch:
                break
            items.extend(item for item in batch if isinstance(item, dict))
            cursor = data.get("nextCursor") if isinstance(data, dict) and data.get("hasMore") else None
            if not cursor:
                break
        return items


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=LOCAL)
    return parsed.astimezone(LOCAL)


def _fmt_time(value: Any) -> str:
    text = str(value or "")
    if not text:
        return ""
    parsed = _timestamp(text)
    if parsed is not None:
        return parsed.strftime("%H:%M")
    return text[:5]


def _display_title(value: Any) -> str:
    return str(value or "(无标题)").strip()


def build_digest(now: datetime, tasks: list[dict[str, Any]], events: list[dict[str, Any]]) -> str:
    today = now.date()
    tomorrow = today + timedelta(days=1)
    active_tasks = [
        task
        for task in tasks
        if not task.get("completed") and not task.get("deletedAt")
    ]
    active_events = [event for event in events if not event.get("deletedAt")]

    today_items: list[str] = []
    tomorrow_items: list[str] = []
    overdue_items: list[tuple[str, str]] = []
    for task in active_tasks:
        due = str(task.get("due") or "").strip()
        if not due:
            continue
        label = f"{_fmt_time(task.get('dueTime'))} {_display_title(task.get('title'))}".strip()
        if due < today.isoformat():
            overdue_items.append((due, label))
        elif due == today.isoformat():
            today_items.append(label)
        elif due == tomorrow.isoformat():
            tomorrow_items.append(label)

    for event in active_events:
        start_at = str(event.get("startAt") or "")
        if not start_at:
            continue
        label = f"{_fmt_time(start_at)} {_display_title(event.get('title'))}".strip()
        location = str(event.get("location") or "").strip()
        if location:
            label += f" @{location}"
        start = _timestamp(start_at)
        event_day = start.date() if start is not None else None
        if event_day == today:
            today_items.append(label)
        elif event_day == tomorrow:
            tomorrow_items.append(label)

    def block(name: str, items: list[str], empty: str = "无") -> str:
        if not items:
            return f"{name}：{empty}"
        unique = sorted(dict.fromkeys(items))
        return f"{name}：" + "；".join(unique)

    overdue_sorted = [f"{label}（{due}）" for due, label in sorted(overdue_items)]
    return "\n".join(
        [
            f"日程清单 {today.strftime('%m-%d')}",
            block("今天", today_items),
            block("明天", tomorrow_items),
            block("逾期", overdue_sorted),
        ]
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-home", help="Hermes profile directory; defaults to the installed scripts/ parent")
    args = parser.parse_args(argv)
    try:
        home = _profile_home(args.profile_home)
        env = _load_profile_env(home)
        server = _server_root(
            env.get("ORIALIS_SERVER_URL", "").strip() or "https://orialis.jxcz.top"
        )
        client = Client(server, env.get("ORIALIS_DEVICE_TOKEN", "").strip())
        tasks = client.list_all("/api/v1/tasks")
        events = client.list_all("/api/v1/schedules")
        print(build_digest(_now(), tasks, events), flush=True)
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"Orialis todo digest failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
