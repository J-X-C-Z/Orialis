from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import pathlib
import shlex
import sqlite3
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from collections.abc import Callable, Mapping, Sequence
from typing import Any, Iterator, Protocol


UTC = dt.timezone.utc
REPORT_FIELDS = ("project", "date", "completed", "in_progress", "decisions", "issues", "next", "important")
REPORT_OPTIONAL_FIELDS = ("contributors", "metrics", "links")


def now() -> str:
    return dt.datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def canonical_hash(value: Any) -> str:
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


class PipelineError(RuntimeError):
    pass


class TaskStageError(PipelineError):
    def __init__(self, phase: str, error: Exception):
        self.phase = phase
        super().__init__(f"{phase} failed: {type(error).__name__}: {error}")


class AgentRunner(Protocol):
    name: str

    def analyze(self, instruction: str, facts: Mapping[str, Any]) -> Mapping[str, Any]: ...


class CommandRunner:
    """JSON-in/JSON-out runner. Codex CLI is the default executable, replaceable by env."""

    def __init__(self, command: str | None = None, timeout: int | None = None):
        self.argv = shlex.split(command or os.getenv("ORIALIS_NEWS_RUNNER_COMMAND", "codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json -"))
        if not self.argv:
            raise ValueError("runner command is empty")
        if timeout is None:
            try:
                timeout = int(os.getenv("ORIALIS_NEWS_RUNNER_TIMEOUT", "180"))
            except ValueError as exc:
                raise PipelineError("ORIALIS_NEWS_RUNNER_TIMEOUT must be an integer between 1 and 900 seconds") from exc
        if isinstance(timeout, bool) or not isinstance(timeout, int) or not 1 <= timeout <= 900:
            raise PipelineError("runner timeout must be an integer between 1 and 900 seconds")
        self.timeout = timeout
        self.name = pathlib.Path(self.argv[0]).name

    def analyze(self, instruction: str, facts: Mapping[str, Any]) -> Mapping[str, Any]:
        prompt = instruction + "\n\nUse only supplied facts. Return one JSON object and no markdown.\nFACTS:\n" + json.dumps(facts, ensure_ascii=False)
        proc = subprocess.run(self.argv, input=prompt, text=True, capture_output=True, timeout=self.timeout, check=False)
        if proc.returncode:
            raise PipelineError(f"runner exited {proc.returncode}: {proc.stderr[-1200:]}")
        candidate: Any = None
        for line in reversed(proc.stdout.splitlines()):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(event, dict):
                if event.get("type") in ("item.completed", "agent_message"):
                    item = event.get("item", event)
                    candidate = item.get("text") or item.get("content") or event.get("text")
                elif isinstance(event.get("result"), str):
                    candidate = event["result"]
                if candidate:
                    break
        if candidate is None:
            candidate = proc.stdout.strip()
        if isinstance(candidate, list):
            candidate = "".join(str(x.get("text", "")) if isinstance(x, dict) else str(x) for x in candidate)
        if not isinstance(candidate, str):
            raise PipelineError("runner response did not contain text")
        try:
            value = json.loads(candidate)
        except json.JSONDecodeError as exc:
            value = self._recover_json(candidate)
            if value is None:
                raise PipelineError("runner response was not valid JSON") from exc
        if not isinstance(value, dict):
            raise PipelineError("runner response must be a JSON object")
        return value

    @staticmethod
    def _recover_json(candidate: str) -> dict[str, Any] | None:
        """Recover a complete JSON object when a CLI adds a short preamble/fence."""
        decoder = json.JSONDecoder()
        for index, char in enumerate(candidate):
            if char != "{":
                continue
            try:
                value, _ = decoder.raw_decode(candidate[index:])
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                return value
        return None


class HttpClient:
    def __init__(self, base_url: str | None = None, token: str | None = None, timeout: int = 12):
        configured_base = base_url or os.getenv("ORIALIS_NEWS_API_BASE_URL")
        if not configured_base:
            news_root = os.getenv("ORIALIS_NEWS_BASE_URL", "http://127.0.0.1:18443/api/v1/news").rstrip("/")
            configured_base = news_root.removesuffix("/api/v1/news")
        self.base_url = configured_base.rstrip("/")
        self.token = token if token is not None else os.getenv("ORIALIS_NEWS_PUBLISHER_TOKEN", os.getenv("ORIALIS_NEWS_API_TOKEN", ""))
        self.publisher_user_id = os.getenv("ORIALIS_NEWS_PUBLISHER_USER_ID", os.getenv("ORIALIS_AGENT_USER_ID", ""))
        self.timeout = timeout

    def request(self, method: str, path: str, payload: Mapping[str, Any] | None = None) -> Any:
        headers = {"Accept": "application/json", "User-Agent": "Orialis-News/0.1"}
        body = None
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=False).encode()
            headers["Content-Type"] = "application/json"
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.base_url + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise PipelineError(f"backend {method} {path} failed: {type(exc).__name__}") from exc

    def get(self, path: str) -> Any:
        return self.request("GET", path)


class PaperclipCommand:
    """Narrow command bridge: configured Paperclip tool reads JSON stdin and returns JSON stdout."""

    def __init__(self, command: str | None = None, timeout: int = 30):
        raw = command if command is not None else os.getenv("ORIALIS_NEWS_PAPERCLIP_COMMAND", "")
        self.argv = shlex.split(raw)
        self.timeout = timeout

    def invoke(self, operation: str, payload: Mapping[str, Any]) -> Any:
        if not self.argv:
            raise PipelineError("Paperclip command is not configured")
        proc = subprocess.run([*self.argv, operation], input=json.dumps(payload, ensure_ascii=False), text=True, capture_output=True, timeout=self.timeout, check=False)
        if proc.returncode:
            raise PipelineError(f"Paperclip command {operation} exited {proc.returncode}: {proc.stderr[-800:]}")
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise PipelineError(f"Paperclip command {operation} returned invalid JSON") from exc


class TaskStore:
    def __init__(self, path: str | pathlib.Path | None = None):
        self.path = pathlib.Path(path or os.getenv("ORIALIS_NEWS_DB", "~/.local/share/orialis-news/pipeline.sqlite3")).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS tasks (
                  task_id TEXT PRIMARY KEY, status TEXT NOT NULL, started_at TEXT NOT NULL,
                  finished_at TEXT, source TEXT NOT NULL, result_json TEXT, error TEXT,
                  input_hash TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 1, phase TEXT
                );
                CREATE TABLE IF NOT EXISTS project_reports (
                  report_hash TEXT PRIMARY KEY, project TEXT NOT NULL, report_date TEXT NOT NULL,
                  received_at TEXT NOT NULL, source TEXT NOT NULL, user_id TEXT NOT NULL,
                  project_id TEXT NOT NULL, report_json TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pending_publications (
                  task_id TEXT PRIMARY KEY, method TEXT NOT NULL, path TEXT NOT NULL,
                  payload_json TEXT NOT NULL, result_json TEXT NOT NULL, payload_hash TEXT NOT NULL,
                  prepared_at TEXT NOT NULL
                );
            """)
            columns = {row[1] for row in db.execute("PRAGMA table_info(tasks)")}
            if "phase" not in columns:
                db.execute("ALTER TABLE tasks ADD COLUMN phase TEXT")

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def begin(self, task_id: str, source: str, facts: Any) -> None:
        digest = canonical_hash(facts)
        with self.connect() as db:
            prior = db.execute("SELECT status,input_hash,source FROM tasks WHERE task_id=?", (task_id,)).fetchone()
            if prior and prior["status"] in ("succeeded", "degraded"):
                if prior["input_hash"] != digest:
                    raise PipelineError("taskId already succeeded with different input")
                raise PipelineError("taskId already succeeded (idempotent replay)")
            if prior and prior["status"] == "running":
                raise PipelineError("taskId is already running")
            if prior and prior["source"] != source:
                raise PipelineError("taskId retry must use the original source")
            if prior and prior["input_hash"] != digest:
                raise PipelineError("taskId retry must use the original input")
            if prior:
                db.execute("UPDATE tasks SET status='running',started_at=?,finished_at=NULL,error=NULL,attempts=attempts+1 WHERE task_id=?", (now(), task_id))
            else:
                db.execute("INSERT INTO tasks(task_id,status,started_at,source,input_hash) VALUES(?,?,?,?,?)", (task_id, "running", now(), source, digest))

    def begin_prepared_retry(self, task_id: str, source: str) -> None:
        with self.connect() as db:
            prior = db.execute("SELECT status,source FROM tasks WHERE task_id=?", (task_id,)).fetchone()
            if not prior or prior["status"] != "failed" or prior["source"] != source:
                raise PipelineError("prepared publication retry requires the original failed task")
            db.execute("UPDATE tasks SET status='running',started_at=?,finished_at=NULL,error=NULL,attempts=attempts+1,phase='publish' WHERE task_id=?", (now(), task_id))

    def finish(self, task_id: str, source: str, result: Any = None, error: str | None = None, phase: str | None = None) -> dict[str, Any]:
        degraded = isinstance(result, dict) and result.get("analysisStatus") == "degraded"
        state = "failed" if error else ("degraded" if degraded else "succeeded")
        phase = phase or ("analysis" if degraded else "complete")
        stamp = now()
        result_json = json.dumps(result, ensure_ascii=False) if result is not None else None
        with self.connect() as db:
            db.execute("UPDATE tasks SET status=?,finished_at=?,result_json=?,error=?,phase=? WHERE task_id=?", (state, stamp, result_json, error, phase, task_id))
            row = db.execute("SELECT * FROM tasks WHERE task_id=?", (task_id,)).fetchone()
        return {"taskId": task_id, "status": state, "phase": phase, "startedAt": row["started_at"], "finishedAt": stamp, "source": source, "result": result, "error": error}

    def pending_publication(self, task_id: str) -> dict[str, Any] | None:
        with self.connect() as db:
            row = db.execute("SELECT * FROM pending_publications WHERE task_id=?", (task_id,)).fetchone()
        if not row:
            return None
        return {"method": row["method"], "path": row["path"], "payload": json.loads(row["payload_json"]), "result": json.loads(row["result_json"]), "payloadHash": row["payload_hash"]}

    def prepare_publication(self, task_id: str, method: str, path: str, payload: Mapping[str, Any], result: Any) -> dict[str, Any]:
        normalized = {"method": method, "path": path, "payload": payload}
        digest = canonical_hash(normalized)
        payload_json = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        result_json = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        with self.connect() as db:
            db.execute("INSERT OR IGNORE INTO pending_publications(task_id,method,path,payload_json,result_json,payload_hash,prepared_at) VALUES(?,?,?,?,?,?,?)", (task_id, method, path, payload_json, result_json, digest, now()))
        pending = self.pending_publication(task_id)
        if pending is None or pending["payloadHash"] != digest:
            raise PipelineError("taskId already has a different prepared publication")
        return pending

    def record_report(self, source: str, report: Mapping[str, Any], user_id: str, project_id: str) -> bool:
        digest = canonical_hash({"report": report, "userId": user_id, "projectId": project_id})
        with self.connect() as db:
            cursor = db.execute("INSERT OR IGNORE INTO project_reports(report_hash,project,report_date,received_at,source,user_id,project_id,report_json) VALUES(?,?,?,?,?,?,?,?)", (digest, report["project"], report["date"], now(), source, user_id, project_id, json.dumps(report, ensure_ascii=False)))
            return cursor.rowcount == 1

    def reports(self, report_date: str, user_id: str) -> list[dict[str, Any]]:
        with self.connect() as db:
            rows = db.execute("SELECT source,user_id,project_id,report_json FROM project_reports WHERE report_date=? AND user_id=? ORDER BY project,received_at", (report_date, user_id)).fetchall()
        return [{"source": r["source"], "userId": r["user_id"], "projectId": r["project_id"], "report": json.loads(r["report_json"])} for r in rows]


def validate_report(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PipelineError("secretary report must be a JSON object")
    missing = [field for field in REPORT_FIELDS if field not in value]
    if missing:
        raise PipelineError("secretary report missing required fields: " + ", ".join(missing))
    unknown = set(value) - set(REPORT_FIELDS) - set(REPORT_OPTIONAL_FIELDS)
    if unknown:
        raise PipelineError("secretary report has unsupported fields: " + ", ".join(sorted(unknown)))
    if not isinstance(value["project"], str) or not value["project"].strip():
        raise PipelineError("project must be a non-empty string")
    try:
        parsed = dt.date.fromisoformat(value["date"])
    except (ValueError, TypeError) as exc:
        raise PipelineError("date must use YYYY-MM-DD") from exc
    if parsed.isoformat() != value["date"]:
        raise PipelineError("date must use YYYY-MM-DD")
    clean: dict[str, Any] = {"project": value["project"].strip(), "date": value["date"]}
    for field in REPORT_FIELDS[2:]:
        entries = value[field]
        if not isinstance(entries, list) or any(not isinstance(item, str) or not item.strip() for item in entries):
            raise PipelineError(f"{field} must be a list of non-empty strings")
        clean[field] = [item.strip() for item in entries]
    for field in REPORT_OPTIONAL_FIELDS:
        if field in value:
            if field == "metrics" and not isinstance(value[field], dict):
                raise PipelineError("metrics must be an object")
            if field != "metrics" and (not isinstance(value[field], list) or any(not isinstance(item, str) for item in value[field])):
                raise PipelineError(f"{field} must be a list of strings")
            clean[field] = value[field]
    return clean


def compact_reports(reports: Sequence[Mapping[str, Any]], report_date: str) -> dict[str, Any]:
    by_project: dict[str, dict[str, Any]] = {}
    seen: set[tuple[str, str, str]] = set()
    counts = {"completed": 0, "inProgress": 0, "issues": 0}
    for item in reports:
        report = validate_report(item["report"])
        if report["date"] != report_date:
            continue
        project_scope = str(item.get("projectId") or report["project"])
        project = by_project.setdefault(project_scope, {"projectId": item.get("projectId"), "project": report["project"], "completed": [], "inProgress": [], "decisions": [], "issues": [], "next": [], "important": [], "sources": []})
        project["sources"].append(item["source"])
        for field, key in (("completed", "completed"), ("in_progress", "inProgress"), ("decisions", "decisions"), ("issues", "issues"), ("next", "next"), ("important", "important")):
            for text in report[field]:
                fingerprint = (project_scope.casefold(), field, text.casefold().strip())
                if fingerprint in seen:
                    continue
                seen.add(fingerprint)
                project[key].append(text)
                if field == "completed": counts["completed"] += 1
                if field == "in_progress": counts["inProgress"] += 1
                if field == "issues": counts["issues"] += 1
    return {"date": report_date, "activeProjects": len(by_project), "counts": counts, "projects": list(by_project.values()), "focus": [x for p in by_project.values() for x in p["important"]]}


def execute_task(store: TaskStore, task_id: str, source: str, facts: Any, operation: Callable[[], Any]) -> dict[str, Any]:
    store.begin(task_id, source, facts)
    try:
        result = operation()
    except Exception as exc:
        return store.finish(task_id, source, error=f"{type(exc).__name__}: {exc}", phase=getattr(exc, "phase", "execution"))
    return store.finish(task_id, source, result=result)


def retry_pending_publication(store: TaskStore, backend: HttpClient, task_id: str, source: str) -> dict[str, Any] | None:
    pending = store.pending_publication(task_id)
    if pending is None:
        return None
    store.begin_prepared_retry(task_id, source)
    try:
        backend.request(pending["method"], pending["path"], pending["payload"])
    except Exception as exc:
        return store.finish(task_id, source, error=f"{type(exc).__name__}: {exc}", phase="publish")
    return store.finish(task_id, source, result=pending["result"])


def submit_prepared_publication(store: TaskStore, backend: HttpClient, task_id: str, path: str, payload: Mapping[str, Any], result: Any) -> Any:
    pending = store.prepare_publication(task_id, "POST", path, payload, result)
    try:
        backend.request(pending["method"], pending["path"], pending["payload"])
    except Exception as exc:
        raise TaskStageError("publish", exc) from exc
    return pending["result"]


PROJECT_ANALYSIS_INSTRUCTION = "Create a concise user-facing project digest from only the supplied secretary reports. Prioritize issues and important decisions, remove duplicates, and preserve all original report objects in rawReports. Never infer missing work. JSON object fields: date,activeProjects,counts,projects,focus,rawReports."


def collect_github(period: str) -> list[dict[str, Any]]:
    # Reuse the backend-owned allowlisted collector so metadata, README, topics,
    # release data, and source parsing stay consistent across refreshes.
    try:
        from scripts.news_sources import fetch_github
        rows = fetch_github(period, os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN"))
    except ImportError as exc:
        raise PipelineError("backend-owned scripts/news_sources.py collector is unavailable in this runtime") from exc
    except Exception as exc:
        raise PipelineError(f"GitHub {period} source collection failed: {type(exc).__name__}: {exc}") from exc
    for row in rows:
        row.setdefault("source", "githot.dev")
        row.setdefault("sourceUrl", "https://githot.dev/weekly" if period == "weekly" else "https://githot.dev/")
        row.setdefault("metadataSource", f"https://api.github.com/repos/{row.get('repository', '')}")
    return rows


def enrich_repositories(repos: Sequence[Mapping[str, Any]], timeout: int = 10) -> list[dict[str, Any]]:
    output = []
    for repo in repos:
        item = dict(repo)
        if "readme" in item or not isinstance(item.get("repository"), str):
            output.append(item)
            continue
        owner_repo = item["repository"].split("/")
        if len(owner_repo) != 2 or not all(owner_repo):
            item["readmeError"] = "repository must be owner/name"
            output.append(item)
            continue
        meta_url = "https://api.github.com/repos/" + urllib.parse.quote(owner_repo[0]) + "/" + urllib.parse.quote(owner_repo[1])
        meta_req = urllib.request.Request(meta_url, headers={"Accept": "application/vnd.github+json", "User-Agent": "Orialis-News/0.1"})
        try:
            with urllib.request.urlopen(meta_req, timeout=timeout) as response:
                meta = json.loads(response.read().decode("utf-8"))
            item["description"] = meta.get("description")
            item["language"] = meta.get("language")
            item["stars"] = meta.get("stargazers_count")
            item["metadataSource"] = meta_url
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            item["metadataError"] = type(exc).__name__
        url = github_readme_api_url(owner_repo[0], owner_repo[1])
        req = urllib.request.Request(url, headers={"Accept": "application/vnd.github.raw+json", "User-Agent": "Orialis-News/0.1"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                item["readme"] = response.read(30000).decode("utf-8", "replace")
                item["readmeSource"] = url
        except (urllib.error.URLError, TimeoutError) as exc:
            item["readmeError"] = type(exc).__name__
        output.append(item)
    return output


def github_readme_api_url(owner: str, repository: str) -> str:
    return "https://api.github.com/repos/" + urllib.parse.quote(owner) + "/" + urllib.parse.quote(repository) + "/readme"


def run_github(period: str, store: TaskStore, runner: AgentRunner | None, backend: HttpClient, *, task_id: str | None = None, publish: bool = False, mock_data: list[dict[str, Any]] | None = None) -> dict[str, Any]:
    if period not in ("daily", "weekly"):
        raise PipelineError("period must be daily or weekly")
    source = "githot.dev"
    task_id = task_id or f"news-github-{period}-{dt.datetime.now(UTC).strftime('%Y%m%d')}-{uuid.uuid4().hex[:8]}"
    if publish:
        replay = retry_pending_publication(store, backend, task_id, source)
        if replay is not None:
            return replay
    def operation() -> Any:
        try:
            base = mock_data if mock_data is not None else collect_github(period)
            if not base:
                raise PipelineError("GitHub returned an empty ranking; keeping the last published cache")
        except Exception as exc:
            raise TaskStageError("collection", exc) from exc
        # Githot already supplies the editorial copy. Preserve it verbatim;
        # the runner argument remains for compatibility with existing callers.
        repos = [dict(row) for row in base]
        for item in repos:
            item["summary"] = item.get("sourceSummary") or item.get("description")
            item["analysisStatus"] = "not_required"
            item["contentOrigin"] = source
        # The brief is a compatibility envelope, not a second editorial summary.
        period_brief = {
            "title": "Githot 日榜" if period == "daily" else "Githot 周榜",
            "summary": f"githot.dev 本期收录 {len(repos)} 个项目。",
            "themes": [],
            "highlights": [],
            "analysisStatus": "not_required",
            "source": source,
            "contentOrigin": source,
            "sourceUrl": "https://githot.dev/weekly" if period == "weekly" else "https://githot.dev/",
        }
        result = {"period": period, "generatedAt": now(), "repositories": repos, "brief": period_brief, "analysisError": None, "analysisStatus": "not_required", "stale": False}
        if publish:
            payload = {"taskId": task_id, "source": source, "generatedAt": result["generatedAt"], "period": period, "result": {"repositories": repos, "brief": period_brief}, "idempotencyKey": task_id}
            if backend.publisher_user_id:
                payload["userId"] = backend.publisher_user_id
            submit_prepared_publication(store, backend, task_id, f"/api/v1/news/publish/github/{period}", payload, result)
        return result
    return execute_task(store, task_id, source, {"period": period, "mock": mock_data is not None, "publish": publish}, operation)


def receive_project_report(store: TaskStore, payload: Mapping[str, Any], expected_user_id: str | None = None) -> dict[str, Any]:
    if not isinstance(payload, Mapping):
        raise PipelineError("payload must be an object")
    allowed = {"taskId", "source", "projectId", "userId", "report"}
    if set(payload) != allowed:
        raise PipelineError("report payload must contain exactly: " + ", ".join(sorted(allowed)))
    if not all(isinstance(payload[k], str) and payload[k].strip() for k in ("taskId", "source", "projectId", "userId")):
        raise PipelineError("taskId, source, projectId and userId are required non-empty strings")
    if not payload["source"].startswith("orialis-project-report/") or len(payload["source"]) <= len("orialis-project-report/"):
        raise PipelineError("source must be orialis-project-report/<stable-source-name>")
    if expected_user_id is not None and payload["userId"] != expected_user_id:
        raise PipelineError("report userId does not match configured publisher identity")
    report = validate_report(payload["report"])
    is_new = store.record_report(payload["source"], report, payload["userId"], payload["projectId"])
    return {"taskId": payload["taskId"], "projectId": payload["projectId"], "userId": payload["userId"], "accepted": is_new, "report": report, "receivedAt": now()}


def run_projects(report_date: str, store: TaskStore, runner: AgentRunner, backend: HttpClient, *, project_user_id: str | None = None, publish: bool = False, task_id: str | None = None) -> dict[str, Any]:
    if not project_user_id:
        raise PipelineError("ORIALIS_NEWS_PROJECT_USER_ID is required to scope private secretary reports")
    reports = store.reports(report_date, project_user_id)
    base = compact_reports(reports, report_date)
    base["rawReports"] = [{"source": x["source"], "userId": x["userId"], "projectId": x["projectId"], "report": x["report"]} for x in reports]
    source = "orialis-project-report/operations-daily"
    task_id = task_id or f"news-projects-{report_date}-{uuid.uuid4().hex[:8]}"
    if publish:
        replay = retry_pending_publication(store, backend, task_id, source)
        if replay is not None:
            return replay
    def operation() -> Any:
        if not reports:
            result = {**base, "summaryStatus": "empty"}
        else:
            try:
                summary = runner.analyze(PROJECT_ANALYSIS_INSTRUCTION, base)
                result = {**base, **summary, "rawReports": base["rawReports"], "summaryStatus": "generated", "analysisStatus": "complete"}
            except Exception as exc:
                result = {**base, "summaryStatus": "unavailable", "analysisStatus": "degraded", "summaryError": f"{type(exc).__name__}: {exc}"}
        if publish:
            if not project_user_id:
                raise PipelineError("ORIALIS_NEWS_PROJECT_USER_ID is required for Projects publish")
            if reports:
                payload = {"taskId": task_id, "source": source, "generatedAt": now(), "result": result, "period": "daily", "reportDate": report_date, "userId": project_user_id, "idempotencyKey": task_id}
                submit_prepared_publication(store, backend, task_id, "/api/v1/news/projects/publish", payload, result)
        return result
    return execute_task(store, task_id, source, {"date": report_date, "userId": project_user_id, "reports": [{"userId": x["userId"], "projectId": x["projectId"], "report": x["report"]} for x in reports], "publish": publish}, operation)


def default_store() -> TaskStore:
    return TaskStore()
