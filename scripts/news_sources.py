#!/usr/bin/env python3
"""Fetch and publish Orialis News source data without an AI processing step."""

from __future__ import annotations

import argparse
import datetime as dt
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlparse
from urllib.request import Request, urlopen
import uuid
from zoneinfo import ZoneInfo

AIHOT = "https://aihot.news"
GITHUB = "https://github.com"
GITHUB_API = "https://api.github.com"
USER_AGENT = "Orialis-News/0.1 (personal non-commercial; source attribution preserved)"
MAX_RESPONSE = 8 * 1024 * 1024


class SourceError(RuntimeError):
    pass


def _request(url: str, *, headers: dict[str, str] | None = None, timeout: int = 20) -> tuple[bytes, dict[str, str]]:
    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise SourceError("source URL must use HTTPS")
    req_headers = {"User-Agent": USER_AGENT, "Accept": "application/json, text/html;q=0.9, */*;q=0.8"}
    req_headers.update(headers or {})
    request = Request(url, headers=req_headers)
    try:
        with urlopen(request, timeout=timeout) as response:
            final = urlparse(response.geturl())
            if final.scheme != "https" or final.hostname != parsed.hostname:
                raise SourceError("source redirected outside its allowlisted host")
            data = response.read(MAX_RESPONSE + 1)
            if len(data) > MAX_RESPONSE:
                raise SourceError("source response exceeded size limit")
            return data, {key.lower(): value for key, value in response.headers.items()}
    except (HTTPError, URLError, TimeoutError) as error:
        raise SourceError(f"source request failed: {error}") from error


def _json(url: str, *, github_token: str | None = None) -> tuple[dict[str, Any], dict[str, str]]:
    headers = {"Accept": "application/json"}
    if github_token:
        headers["Authorization"] = f"Bearer {github_token}"
    body, response_headers = _request(url, headers=headers)
    try:
        value = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceError("source returned invalid JSON") from error
    if not isinstance(value, dict):
        raise SourceError("source JSON response must be an object")
    return value, response_headers


def normalize_aihot_hot(payload: dict[str, Any]) -> list[dict[str, Any]]:
    normalized = []
    for raw in payload.get("items", []):
        if not isinstance(raw, dict):
            continue
        links = raw.get("links") if isinstance(raw.get("links"), dict) else {}
        story_url = links.get("story") if isinstance(links.get("story"), str) else None
        story_id = story_public_id(story_url)
        normalized.append({
            "id": story_id,
            "itemId": raw.get("id"),
            "rank": raw.get("rank"),
            "title": raw.get("title", ""),
            "heat": None,
            "trend": None,
            "status": None,
            "summary": None,
            "latestUpdate": raw.get("latestAt"),
            "sourceCount": raw.get("sourceCount"),
            "signalCount": raw.get("signalCount"),
            "participantCount": raw.get("participantCount"),
            "sourceNames": raw.get("sourceNames", []),
            "time": raw.get("latestAt"),
            "source": raw.get("source"),
            "links": links,
            "storyAvailable": story_id is not None,
        })
    normalized.sort(key=lambda item: item["rank"] if isinstance(item["rank"], int) else 999)
    return normalized[:10]


def story_public_id(story_url: str | None) -> str | None:
    if not story_url:
        return None
    parsed = urlparse(story_url)
    if parsed.scheme != "https" or parsed.hostname not in {"aihot.news", "aihot.virxact.com"}:
        return None
    match = re.fullmatch(r"/story/([0-9a-fA-F-]{36})/?", parsed.path)
    return match.group(1) if match else None


def normalize_aihot_items(payload: dict[str, Any]) -> list[dict[str, Any]]:
    output = []
    for raw in payload.get("items", []):
        if not isinstance(raw, dict):
            continue
        output.append({
            "id": raw.get("id"),
            "title": raw.get("title", ""),
            "originalTitle": raw.get("originalTitle"),
            "summary": raw.get("summary"),
            "source": raw.get("source", {}),
            "publishedAt": raw.get("publishedAt"),
            "discoveredAt": raw.get("discoveredAt"),
            "category": raw.get("category"),
            "url": (raw.get("links") or {}).get("original") if isinstance(raw.get("links"), dict) else None,
            "links": raw.get("links", {}),
            "score": raw.get("score"),
            "selected": raw.get("selected", False),
            "attribution": raw.get("attribution", {"name": "AIHOT", "url": "https://aihot.news"}),
        })
    return output


def _text(value: str) -> str:
    return " ".join(html.unescape(value).split())


class TrendingParser(HTMLParser):
    """Extract each official Trending card and its visible ranking metadata."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[dict[str, Any]] = []
        self.row: dict[str, Any] | None = None
        self.capture: list[tuple[str, str]] = []
        self.text_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attrs_map = {key: value or "" for key, value in attrs}
        classes = attrs_map.get("class", "").split()
        if tag == "article" and "Box-row" in classes:
            self.row = {"links": [], "text": []}
            self.rows.append(self.row)
        if self.row is None:
            return
        if tag == "a" and attrs_map.get("href", "").count("/") == 2 and attrs_map["href"].startswith("/"):
            path = attrs_map["href"].strip("/")
            if all(part and part not in {"topics", "sponsors"} for part in path.split("/")):
                self.row["links"].append(path)
        for key in ("class", "aria-label", "datetime", "title"):
            val = attrs_map.get(key, "")
            if val:
                self.capture.append((tag, val))
        if tag in {"p", "h1", "h2", "h3", "span", "a", "time"}:
            self.text_parts.append("")

    def handle_data(self, data: str) -> None:
        if self.row is not None:
            self.row["text"].append(_text(data))

    def handle_endtag(self, tag: str) -> None:
        if tag == "article" and self.row is not None:
            self.row = None


def parse_trending_html(document: str, period: str) -> list[dict[str, Any]]:
    repos: list[dict[str, Any]] = []
    for match in re.finditer(r'<article\s+class="Box-row"[^>]*>(.*?)</article>', document, re.DOTALL):
        fragment = match.group(1)
        name_match = re.search(r'<h2\b[^>]*>.*?<a\b[^>]*href="/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)"', fragment, re.DOTALL)
        if not name_match:
            continue
        owner, name = name_match.groups()
        full_name = f"{owner}/{name}"
        text_fragment = re.sub(r"<[^>]+>", " ", fragment)
        joined = _text(text_fragment)
        repo_url = f"https://github.com/{quote(owner, safe='')}/{quote(name, safe='')}"
        stars_in_period = None
        pattern = r"([\d,]+)\s+stars?\s+" + ("today" if period == "daily" else "this week")
        match = re.search(pattern, joined, re.IGNORECASE)
        if match:
            stars_in_period = int(match.group(1).replace(",", ""))
        language_match = re.search(r'<span\s+itemprop="programmingLanguage"[^>]*>(.*?)</span>', fragment, re.DOTALL)
        language = _text(re.sub(r"<[^>]+>", " ", language_match.group(1))) if language_match else None
        description_match = re.search(r'<p\b[^>]*class="[^"]*color-fg-muted[^"]*"[^>]*>(.*?)</p>', fragment, re.DOTALL)
        description = _text(re.sub(r"<[^>]+>", " ", description_match.group(1))) if description_match else None
        repos.append({
            "repository": full_name,
            "ranking": len(repos) + 1,
            "period": period,
            "description": description or None,
            "language": language,
            "stars": None,
            "starsInPeriod": stars_in_period,
            "topics": [],
            "readme": None,
            "recentRelease": None,
            "summary": None,
            "features": [],
            "value": None,
            "useCases": [],
            "repositoryUrl": repo_url,
        })
        if len(repos) >= 25:
            break
    if not repos:
        raise SourceError("could not parse repository cards from the official GitHub Trending page")
    return repos


def _github_api(path: str, token: str | None) -> dict[str, Any]:
    value, _ = _json(f"{GITHUB_API}{path}", github_token=token)
    return value


def enrich_repository(item: dict[str, Any], token: str | None) -> dict[str, Any]:
    full_name = item["repository"]
    owner, name = full_name.split("/", 1)
    encoded = quote(owner, safe="") + "/" + quote(name, safe="")
    try:
        meta = _github_api(f"/repos/{encoded}", token)
        if meta.get("full_name", "").lower() != full_name.lower() or urlparse(meta.get("html_url", "")).hostname != "github.com":
            raise SourceError("GitHub metadata did not match the requested repository")
        item["description"] = meta.get("description")
        item["language"] = meta.get("language")
        item["stars"] = meta.get("stargazers_count")
        item["topics"] = meta.get("topics", [])
        item["repositoryUrl"] = meta.get("html_url")
        branch = meta.get("default_branch")
        if branch and re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", branch):
            raw_url = f"https://raw.githubusercontent.com/{encoded}/{quote(branch, safe='/')}/README.md"
            try:
                body, _ = _request(raw_url, headers={"Accept": "text/plain"}, timeout=15)
                item["readme"] = body.decode("utf-8", errors="replace")[:12000]
            except SourceError:
                item["readme"] = None
        try:
            release = _github_api(f"/repos/{encoded}/releases/latest", token)
            item["recentRelease"] = {
                "tagName": release.get("tag_name"),
                "name": release.get("name"),
                "publishedAt": release.get("published_at"),
                "url": release.get("html_url"),
            }
        except SourceError:
            item["recentRelease"] = None
    except SourceError as error:
        item["metadataError"] = str(error)
    item["generatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    return item


def _state_path() -> Path:
    configured = os.getenv("ORIALIS_NEWS_REFRESH_STATE")
    return Path(configured) if configured else Path.home() / ".cache" / "orialis-news" / "refresh-state.json"


def _load_state() -> dict[str, Any]:
    try:
        value = json.loads(_state_path().read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _report_bucket(period: str) -> str:
    today = dt.datetime.now(ZoneInfo("Asia/Shanghai")).date()
    if period == "daily":
        return today.isoformat()
    if period == "weekly":
        iso = today.isocalendar()
        return f"{iso.year}-W{iso.week:02d}"
    return today.strftime("%Y-%m")


def _report_due(state: dict[str, Any], period: str) -> bool:
    return state.get("reportBuckets", {}).get(period) != _report_bucket(period)


def _record_report_success(state: dict[str, Any], period: str) -> None:
    state.setdefault("reportBuckets", {})[period] = _report_bucket(period)
    path = _state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    try:
        temporary.chmod(0o600)
    except OSError:
        pass
    temporary.replace(path)


def fetch_aihot(report_periods: set[str] | None = None) -> dict[str, Any]:
    hot, _ = _json(f"{AIHOT}/api/v1/hot-topics")
    items, _ = _json(f"{AIHOT}/api/v1/items?{urlencode({'mode': 'selected', 'window': '7d', 'limit': 100})}")
    hot_items = normalize_aihot_hot(hot)
    hot_by_story: dict[str, list[dict[str, Any]]] = {}
    for item in hot_items:
        if item.get("id"):
            hot_by_story.setdefault(item["id"], []).append(item)
    events: list[dict[str, Any]] = []
    event_errors: list[dict[str, str]] = []
    # Fetch each story once, then reuse the source's processed fields in both
    # the hot cards and the event-detail cache.
    for story_id, cards in hot_by_story.items():
        try:
            story_response, _ = _json(f"{AIHOT}/api/v1/stories/{quote(story_id, safe='')}")
            story = story_response.get("story")
            if not isinstance(story, dict) or story.get("publicId") != story_id:
                raise SourceError("AIHOT story response did not match the requested story")
            for card in cards:
                if isinstance(story.get("digest"), str):
                    card["summary"] = story["digest"]
                if isinstance(story.get("status"), str):
                    card["status"] = story["status"]
                if isinstance(story.get("latest"), str):
                    card["latestUpdate"] = story["latest"]
            story["itemId"] = cards[0].get("itemId")
            events.append(story)
        except SourceError as error:
            event_errors.append({"storyId": story_id, "error": str(error)})
    datasets: list[tuple[str, Any]] = [
        ("hot", hot_items),
        ("items", normalize_aihot_items(items)),
    ]
    report_periods = {"daily", "weekly", "monthly"} if report_periods is None else report_periods
    for period, endpoint in (("daily", "dailies/latest"), ("weekly", "weeklies/latest"), ("monthly", "monthlies/latest")):
        if period not in report_periods:
            continue
        try:
            report, _ = _json(f"{AIHOT}/api/v1/{endpoint}")
            report_data = report.get("report")
            if not isinstance(report_data, dict):
                raise SourceError(f"AIHOT {period} report is not available")
            datasets.append((f"reports/{period}", report_data))
        except SourceError as error:
            datasets.append((f"reports/{period}", {"data": None, "sourceError": str(error)}))
    return {"datasets": datasets, "events": events, "eventErrors": event_errors}


def fetch_github(period: str, token: str | None) -> list[dict[str, Any]]:
    if period not in {"daily", "weekly"}:
        raise SourceError("GitHub period must be daily or weekly")
    body, _ = _request(f"{GITHUB}/trending?since={period}", headers={"Accept": "text/html"})
    repos = parse_trending_html(body.decode("utf-8", errors="replace"), period)
    # Full metadata for the first ten; every trending entry remains in the
    # persisted ranking even when API rate limits prevent enrichment.
    for item in repos[:10]:
        enrich_repository(item, token)
    for item in repos[10:]:
        item["generatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    return repos


def publish(base_url: str, token: str, path: str, source: str, result: Any, *, period: str | None = None, project_id: str | None = None, publisher_user_id: str | None = None, error: str | None = None, expected_status: str = "succeeded") -> dict[str, Any]:
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    task_id = str(uuid.uuid4())
    body: dict[str, Any] = {
        "taskId": task_id,
        "source": source,
        "generatedAt": now,
        "result": result,
        "idempotencyKey": task_id,
    }
    if period:
        body["period"] = period
    if project_id:
        body["projectId"] = project_id
    if publisher_user_id:
        body["userId"] = publisher_user_id
    if error:
        body["error"] = error
    url = base_url.rstrip("/") + path
    request = Request(url, data=json.dumps(body, ensure_ascii=False).encode("utf-8"), method="POST", headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json", "Accept": "application/json", "User-Agent": USER_AGENT})
    try:
        with urlopen(request, timeout=30) as response:
            result_body = response.read(MAX_RESPONSE + 1)
    except (HTTPError, URLError, TimeoutError) as error:
        raise SourceError(f"publisher request failed for {path}: {error}") from error
    try:
        response_json = json.loads(result_body)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SourceError("publisher returned invalid JSON") from error
    if response_json.get("status") != expected_status:
        raise SourceError(f"publish task {task_id} did not reach {expected_status}: {response_json}")
    return response_json


def _publish_or_print(args: argparse.Namespace, path: str, source: str, result: Any, *, period: str | None = None) -> dict[str, Any] | None:
    if args.dry_run:
        print(json.dumps({"path": path, "source": source, "result": result}, ensure_ascii=False))
        return None
    return publish(args.base_url, args.publisher_token, path, source, result, period=period, publisher_user_id=args.publisher_user_id)


def run_refresh(args: argparse.Namespace) -> None:
    modes = ["aihot", "github-daily", "github-weekly"] if args.refresh == "all" else [args.refresh]
    for mode in modes:
      if mode == "aihot":
        state = _load_state()
        due_periods = {period for period in ("daily", "weekly", "monthly") if _report_due(state, period)}
        try:
            result = fetch_aihot(due_periods)
        except SourceError as error:
            keys = ["aihot:hot", "aihot:items"] + [f"aihot:report:{period}" for period in due_periods]
            _record_failure(args, "aihot.news", keys, str(error))
            raise
        for kind, data in result["datasets"]:
            if isinstance(data, dict) and data.get("sourceError"):
                print(json.dumps({"dataset": kind, "error": data["sourceError"], "cacheAction": "preserve-existing"}, ensure_ascii=False), file=sys.stderr)
                _record_failure(args, "aihot.news", [f"aihot:report:{kind.split('/', 1)[1]}"], data["sourceError"])
                continue
            response = _publish_or_print(args, f"/publish/aihot/{kind}", "aihot.news", data)
            if response and kind.startswith("reports/"):
                _record_report_success(state, kind.split("/", 1)[1])
            if response:
                print(json.dumps({"dataset": kind, "taskId": response["taskId"], "status": response["status"]}, ensure_ascii=False))
        for story in result["events"]:
            story_id = story["publicId"]
            try:
                response = _publish_or_print(args, "/publish/aihot/events", "aihot.news", story)
                if response:
                    print(json.dumps({"dataset": "event", "eventId": story_id, "taskId": response["taskId"], "status": response["status"]}, ensure_ascii=False))
            except SourceError as error:
                print(json.dumps({"dataset": "event", "eventId": story_id, "error": str(error)}, ensure_ascii=False), file=sys.stderr)
                _record_failure(args, "aihot.news", [f"aihot:event:{story_id}"], str(error))
        for failure in result["eventErrors"]:
            print(json.dumps({"dataset": "event", "eventId": failure["storyId"], "error": failure["error"], "cacheAction": "preserve-existing"}, ensure_ascii=False), file=sys.stderr)
            _record_failure(args, "aihot.news", [f"aihot:event:{failure['storyId']}"], failure["error"])
      elif mode.startswith("github-"):
        period = mode.removeprefix("github-")
        try:
            items = fetch_github(period, args.github_token)
        except SourceError as error:
            _record_failure(args, "github.com/trending", [f"github:{period}"], str(error))
            raise
        response = _publish_or_print(args, f"/publish/github/{period}", "github.com/trending", items, period=period)
        if response:
            print(json.dumps({"dataset": f"github/{period}", "count": len(items), "taskId": response["taskId"], "status": response["status"]}, ensure_ascii=False))


def _record_failure(args: argparse.Namespace, source: str, cache_keys: list[str], message: str) -> None:
    if args.dry_run:
        print(json.dumps({"source": source, "cacheKeys": cache_keys, "error": message, "cacheAction": "preserve-existing"}, ensure_ascii=False), file=sys.stderr)
        return
    publish(args.base_url, args.publisher_token, "/publish/failure", source, {"cacheKeys": cache_keys}, publisher_user_id=args.publisher_user_id, error=message[:2048], expected_status="failed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--refresh", choices=("aihot", "github-daily", "github-weekly", "all"), required=True)
    parser.add_argument("--dry-run", action="store_true", help="fetch and normalize sources without publishing")
    parser.add_argument("--base-url", default=os.getenv("ORIALIS_NEWS_BASE_URL", "http://127.0.0.1:18443/api/v1/news"))
    parser.add_argument("--publisher-token", default=os.getenv("ORIALIS_NEWS_PUBLISHER_TOKEN"))
    parser.add_argument("--publisher-user-id", default=os.getenv("ORIALIS_AGENT_USER_ID"))
    parser.add_argument("--github-token", default=os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN"))
    args = parser.parse_args()
    if not args.dry_run and (not args.publisher_token or not args.publisher_user_id):
        parser.error("publisher token and bound publisher user id are required (set ORIALIS_NEWS_PUBLISHER_TOKEN and ORIALIS_AGENT_USER_ID)")
    try:
        run_refresh(args)
        return 0
    except SourceError as error:
        print(f"news source refresh failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
