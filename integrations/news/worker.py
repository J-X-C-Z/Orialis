"""Scoped Paperclip process worker with durable publication and issue disposition."""
from __future__ import annotations

import argparse
import json
import os
from collections.abc import Callable, Mapping
from typing import Any
from urllib.parse import quote

from scripts import news_sources
from .pipeline import HttpClient, PipelineError, TaskStore, now, run_github


class WorkerApi(HttpClient):
    def __init__(self, environment: Mapping[str, str]):
        base = environment.get("PAPERCLIP_API_URL", "")
        token = environment.get("PAPERCLIP_API_KEY", "")
        run_id = environment.get("PAPERCLIP_RUN_ID", "")
        if not base or not token or not run_id:
            raise PipelineError("Paperclip API URL, run identity and run credential are required")
        super().__init__(base_url=base, token=token)
        self.run_id = run_id

    def request(self, method: str, path: str, payload: Mapping[str, Any] | None = None) -> Any:
        # Keep run attribution on every request, including all issue mutations.
        import urllib.error
        import urllib.request
        headers = {"Accept": "application/json", "Content-Type": "application/json", "User-Agent": "Orialis-News/0.1", "Authorization": "Bearer " + self.token, "X-Paperclip-Run-Id": self.run_id}
        data = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
        request = urllib.request.Request(self.base_url + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=15) as response:
                return json.loads(response.read())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            # Never echo server bodies, request headers, or run credentials.
            raise PipelineError(f"Paperclip {method} {path} failed: {type(exc).__name__}") from exc


def object_value(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise PipelineError(f"{label} must be an object")
    return value


def scope(api: WorkerApi, environment: Mapping[str, str], workflow: str) -> tuple[Mapping[str, Any], Mapping[str, Any], str]:
    company = environment.get("ORIALIS_NEWS_PAPERCLIP_COMPANY_ID", "")
    project = environment.get("ORIALIS_NEWS_PAPERCLIP_PROJECT_ID", "")
    if not company or not project:
        raise PipelineError("explicit Orialis News company and project scope are required")
    identity = object_value(api.get("/api/agents/me"), "agent identity")
    run = object_value(api.get("/api/heartbeat-runs/" + quote(api.run_id, safe="")), "run")
    if run.get("id") != api.run_id or run.get("agentId") != identity.get("id") or run.get("companyId") != company or identity.get("companyId") != company:
        raise PipelineError("run and agent do not match the configured company")
    for key, actual in (("PAPERCLIP_AGENT_ID", identity.get("id")), ("PAPERCLIP_COMPANY_ID", company)):
        if environment.get(key) and environment[key] != actual:
            raise PipelineError("injected Paperclip identity does not match the authenticated run")
    if run.get("status") not in ("running", "queued"):
        raise PipelineError("worker run is not active")
    context = object_value(run.get("contextSnapshot"), "run context")
    issue_id = context.get("issueId")
    if not isinstance(issue_id, str) or not issue_id:
        raise PipelineError("run context did not contain an issue identity")
    if context.get("projectId") and context["projectId"] != project:
        raise PipelineError("run context project is outside Orialis News")
    issue = object_value(api.get("/api/issues/" + quote(issue_id, safe="")), "issue")
    if issue.get("id") != issue_id or issue.get("companyId") != company or issue.get("projectId") != project or issue.get("assigneeAgentId") != identity.get("id"):
        raise PipelineError("issue is outside the worker company, project or assignment")
    if issue.get("originKind") != "routine_execution":
        raise PipelineError("worker only handles routine execution issues")
    configured = {"aihot": environment.get("ORIALIS_NEWS_AIHOT_ROUTINE_ID"), "github-daily": environment.get("ORIALIS_NEWS_GITHUB_DAILY_ROUTINE_ID"), "github-weekly": environment.get("ORIALIS_NEWS_GITHUB_WEEKLY_ROUTINE_ID")}
    matches = [key for key, routine in configured.items() if routine and routine == issue.get("originId")]
    if len(matches) != 1 or (workflow == "aihot") != (matches[0] == "aihot"):
        raise PipelineError("issue did not originate from the configured workflow routine")
    if issue.get("executionRunId") and issue["executionRunId"] != api.run_id:
        raise PipelineError("another run owns issue execution")
    return issue, context, matches[0]


class WorkerLedger:
    def __init__(self, store: TaskStore):
        self.store = store
        with store.connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS paperclip_news_workflows(issue_id TEXT PRIMARY KEY,workflow TEXT NOT NULL,status TEXT NOT NULL,receipt_json TEXT,updated_at TEXT NOT NULL)")

    def read(self, issue_id: str, workflow: str) -> dict[str, Any] | None:
        with self.store.connect() as db:
            row = db.execute("SELECT workflow,status,receipt_json FROM paperclip_news_workflows WHERE issue_id=?", (issue_id,)).fetchone()
        if not row:
            return None
        if row["workflow"] != workflow:
            raise PipelineError("issue already has a different worker workflow")
        return {"status": row["status"], "receipt": json.loads(row["receipt_json"]) if row["receipt_json"] else None}

    def begin(self, issue_id: str, workflow: str) -> None:
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            prior = db.execute("SELECT status FROM paperclip_news_workflows WHERE issue_id=?", (issue_id,)).fetchone()
            if prior and prior["status"] != "failed":
                raise PipelineError("workflow already running or published; do not repeat execution")
            db.execute("INSERT INTO paperclip_news_workflows(issue_id,workflow,status,updated_at) VALUES (?,?,'running',?) ON CONFLICT(issue_id) DO UPDATE SET status='running',updated_at=excluded.updated_at", (issue_id, workflow, now()))

    def finish(self, issue_id: str, workflow: str, receipt: Mapping[str, Any], published: bool) -> None:
        with self.store.connect() as db:
            db.execute("UPDATE paperclip_news_workflows SET status=?,receipt_json=?,updated_at=? WHERE issue_id=? AND workflow=?", ("published" if published else "failed", json.dumps(receipt, ensure_ascii=False), now(), issue_id, workflow))


def completed_publication(store: TaskStore, task_id: str) -> dict[str, Any] | None:
    with store.connect() as db:
        prior = db.execute("SELECT * FROM tasks WHERE task_id=? AND status IN ('succeeded','degraded')", (task_id,)).fetchone()
        prepared = db.execute("SELECT task_id FROM pending_publications WHERE task_id=?", (task_id,)).fetchone()
    if prior and prepared:
        return {"taskId": task_id, "status": prior["status"], "result": json.loads(prior["result_json"]), "reusedPublication": True}
    return None


def execute(workflow: str, task_id: str, store: TaskStore) -> dict[str, Any]:
    if workflow.startswith("github-"):
        prior = completed_publication(store, task_id)
        if prior:
            return prior
        return run_github(workflow.removeprefix("github-"), store, None, HttpClient(), publish=True, task_id=task_id)
    args = argparse.Namespace(refresh="aihot", dry_run=False, base_url=os.getenv("ORIALIS_NEWS_BASE_URL", ""), publisher_token=os.getenv("ORIALIS_NEWS_PUBLISHER_TOKEN", ""), publisher_user_id=os.getenv("ORIALIS_NEWS_PUBLISHER_USER_ID", ""), github_token=None)
    if not args.base_url or not args.publisher_token or not args.publisher_user_id:
        raise PipelineError("publisher runtime is incomplete")
    news_sources.run_refresh(args)
    return {"taskId": task_id, "status": "succeeded", "workflow": "aihot", "published": True}


def run_worker(api: WorkerApi, environment: Mapping[str, str], workflow: str, store: TaskStore | None = None, operation: Callable[[str, str, TaskStore], dict[str, Any]] = execute) -> dict[str, Any]:
    issue, context, resolved = scope(api, environment, workflow)
    issue_id = str(issue["id"])
    if issue.get("status") == "done":
        return {"issueId": issue_id, "status": "done", "reusedDisposition": True}
    if issue.get("status") == "cancelled":
        raise PipelineError("cancelled routine issue must not execute")
    store = store or TaskStore()
    ledger = WorkerLedger(store)
    prior = ledger.read(issue_id, resolved)
    api.request("POST", f"/api/issues/{quote(issue_id, safe='')}/checkout", {"agentId": environment.get("PAPERCLIP_AGENT_ID") or object_value(api.get("/api/agents/me"), "identity")["id"], "expectedStatuses": ["todo", "backlog", "blocked", "in_progress"]})
    receipt = prior["receipt"] if prior and prior["status"] == "published" else None
    task_id = "paperclip-news-" + resolved + "-" + issue_id
    if receipt is None and prior and prior["status"] == "running" and resolved.startswith("github-"):
        receipt = completed_publication(store, task_id)
        if receipt:
            ledger.finish(issue_id, resolved, receipt, True)
    if receipt is None:
        started = False
        try:
            if prior and prior["status"] == "running":
                raise PipelineError("previous execution has no confirmed publication receipt; do not repeat work")
            if context.get("allowDeliverableWork") is False:
                raise PipelineError("status-only recovery has no durable publication receipt; no collection or model call allowed")
            ledger.begin(issue_id, resolved)
            started = True
            receipt = operation(resolved, task_id, store)
            published = receipt.get("status") in ("succeeded", "degraded")
            ledger.finish(issue_id, resolved, receipt, published)
            if not published:
                raise PipelineError("news publication did not succeed")
        except Exception as error:
            if started:
                ledger.finish(issue_id, resolved, {"taskId": task_id, "status": "failed", "errorType": type(error).__name__}, False)
            api.request("PATCH", f"/api/issues/{quote(issue_id, safe='')}", {"status": "blocked", "comment": "Orialis News worker未完成发布；本轮已停止，需检查后再恢复。错误类型：" + type(error).__name__})
            return {"issueId": issue_id, "status": "blocked", "errorType": type(error).__name__}
    # Durable receipt comes before disposition: a failed status write can be
    # retried by recovery without collecting, publishing or analyzing again.
    api.request("PATCH", f"/api/issues/{quote(issue_id, safe='')}", {"status": "done", "comment": f"Orialis News已发布并保存回执；workflow={resolved}；taskId={receipt.get('taskId', task_id)}；publicationStatus={receipt.get('status')}。"})
    persisted = object_value(api.get("/api/issues/" + quote(issue_id, safe="")), "persisted issue")
    if persisted.get("status") != "done" or persisted.get("companyId") != issue.get("companyId") or persisted.get("assigneeAgentId") != issue.get("assigneeAgentId"):
        raise PipelineError("issue completion did not persist within the worker scope")
    return {"issueId": issue_id, "status": "done", "publicationStatus": receipt.get("status"), "taskId": receipt.get("taskId", task_id), "reusedPublication": bool(prior and (prior["status"] == "published" or receipt.get("reusedPublication")))}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow", choices=("aihot", "github"), required=True)
    args = parser.parse_args(argv)
    try:
        result = run_worker(WorkerApi(os.environ), os.environ, args.workflow)
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result["status"] == "done" else 2
    except PipelineError as error:
        print(json.dumps({"status": "blocked", "errorType": type(error).__name__, "reason": str(error)}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
