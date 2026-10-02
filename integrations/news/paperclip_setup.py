"""Read-only by default Paperclip routine planner/applicator using real routine APIs."""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from typing import Any

from .pipeline import PipelineError


RUNBOOKS = [
    {
        "key": "aihot-refresh", "title": "Orialis News · AIHOT Source Refresh",
        "cronExpression": "*/5 * * * *", "timezone": "Asia/Shanghai", "runnerKind": "process",
        "description": "Run only the pure source collector command configured on this Paperclip process agent: python3 scripts/news_sources.py --refresh aihot. This collector fetches/normalizes/caches licensed AIHOT source data and publishes with source=aihot.news. Do not invoke Codex, any AgentRunner, or an LLM. Respect the official source cache TTL of at least 60 seconds and keep the last cache on fetch failure. Preserve AIHOT attribution and source fields. This workflow does not mirror content to a public surface.",
    },
    {
        "key": "github-daily", "title": "Orialis News · GitHub Daily",
        "cronExpression": "0 18 * * *", "timezone": "Asia/Shanghai",
        "description": "Collect a fresh GitHub daily trending ranking and repository metadata/README; make one grounded read-only Agent Runner call for per-repository briefs and the full-period overview. Publish source=github.com/trending to POST /api/v1/news/publish/github/daily with taskId, source, generatedAt, period=daily, result={repositories:[...],brief:{title,summary,themes,highlights,analysisStatus,source}}, and idempotencyKey=taskId. If analysis fails, keep the full ranking and publish a deterministic brief from observed repository descriptions with analysisStatus=unavailable. Keep taskId stable across retries and record taskId/status/startedAt/finishedAt/source/result/error. Runner command comes from ORIALIS_NEWS_RUNNER_COMMAND; default: codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json -. Do not inspect unrelated project code or send user notifications.",
        "runnerKind": "llm",
    },
    {
        "key": "github-weekly", "title": "Orialis News · GitHub Weekly",
        "cronExpression": "15 18 * * 1", "timezone": "Asia/Shanghai",
        "description": "Fetch a new GitHub weekly trending ranking (never concatenate daily reports), retrieve metadata and README, and make one grounded read-only Agent Runner call for per-repository briefs plus the full-period overview. POST /api/v1/news/publish/github/weekly with source=github.com/trending, period=weekly, result={repositories:[...],brief:{title,summary,themes,highlights,analysisStatus,source}}, and stable taskId/idempotencyKey. If analysis fails, keep the full ranking and publish a deterministic brief from observed repository descriptions with analysisStatus=unavailable. Audit taskId/status/startedAt/finishedAt/source/result/error. Runner is configurable; default codex exec --ephemeral --sandbox read-only --skip-git-repo-check --json -. Do not send user notifications.",
        "runnerKind": "llm",
    },
    {
        "key": "projects-daily", "title": "Orialis News · Projects Daily",
        "cronExpression": "0 19 * * *", "timezone": "Asia/Shanghai",
        "description": "Read only secretary reports received through the Orialis News report protocol. Never scan project repositories. Validate all required fields; merge, deduplicate and prioritize issues/important decisions; preserve rawReports and publish deterministic aggregation if the Agent Runner fails. POST /api/v1/news/projects/publish with source=orialis-project-report/operations-daily, period=daily, reportDate=YYYY-MM-DD, userId bound to the configured publisher identity, result object, stable taskId/idempotencyKey. Keep reports scoped by userId and projectId. Audit taskId/status/startedAt/finishedAt/source/result/error.",
        "runnerKind": "llm",
    },
]


class PaperclipApi:
    def __init__(self, base: str, token: str = "", timeout: int = 6):
        self.base = base.rstrip("/")
        self.token = token
        self.timeout = timeout

    def request(self, method: str, path: str, payload: Any = None) -> Any:
        headers = {"Accept": "application/json"}
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload, ensure_ascii=False).encode()
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.base + path, data=body, headers=headers, method=method)
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=self.timeout) as response:
                return json.loads(response.read().decode())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise PipelineError(f"Paperclip {method} {path} failed: {type(exc).__name__}") from exc


def unwrap_list(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [x for x in value if isinstance(x, dict)]
    if isinstance(value, dict):
        for key in ("items", "data", "agents", "routines"):
            if isinstance(value.get(key), list):
                return [x for x in value[key] if isinstance(x, dict)]
    return []


def apply(company_id: str, agent_ids: dict[str, str], *, base_url: str, token: str, do_apply: bool, project_id: str = "", enable_triggers: bool = False) -> dict[str, Any]:
    api = PaperclipApi(base_url, token)
    routes: list[dict[str, Any]] = []
    try:
        agents = unwrap_list(api.request("GET", f"/api/companies/{company_id}/agents"))
        routines = unwrap_list(api.request("GET", f"/api/companies/{company_id}/routines"))
        projects = unwrap_list(api.request("GET", f"/api/companies/{company_id}/projects"))
        readable = True
    except PipelineError as exc:
        agents, routines, readable = [], [], False
        read_error = str(exc)
    by_id = {a.get("id"): a for a in agents}
    project_ids = {p.get("id") for p in projects}
    assigned = {key: by_id.get(agent_id) for key, agent_id in agent_ids.items() if agent_id}
    if any(agent_id not in by_id for agent_id in agent_ids.values() if agent_id) and readable:
        raise PipelineError("an assigned agent ID is not in the selected Paperclip company")
    if do_apply:
        if not project_id:
            raise PipelineError("apply requires --project-id for the Orialis News operations project")
        if project_id not in project_ids:
            raise PipelineError("project ID is not in the selected Paperclip company; refusing cross-company or unrelated-project setup")
        if set(agent_ids) != {"aihot", "github", "projects"} or not all(agent_ids.values()):
            raise PipelineError("apply requires explicit --aihot-process-agent-id, --github-agent-id and --projects-agent-id")
        if len(set(agent_ids.values())) != 3:
            raise PipelineError("AIHOT process worker and GitHub/Projects runner agents must be distinct")
        if readable:
            if assigned["aihot"].get("adapterType") != "process":
                raise PipelineError("AIHOT schedule must be assigned to a Paperclip process adapter agent")
            process_config = assigned["aihot"].get("adapterConfig") or {}
            process_args = process_config.get("args", [])
            if isinstance(process_args, str):
                process_args = process_args.split()
            if "scripts/news_sources.py" not in process_args or not any("--refresh" in str(arg) for arg in process_args) or not any("aihot" in str(arg) for arg in process_args):
                raise PipelineError("AIHOT process agent must be preconfigured with scripts/news_sources.py --refresh aihot")
            if assigned["github"].get("adapterType") == "process" or assigned["projects"].get("adapterType") == "process":
                raise PipelineError("GitHub and Projects routines require a configured LLM Agent Runner adapter")
    for plan in RUNBOOKS:
        existing = next((r for r in routines if r.get("title") == plan["title"]), None)
        agent_key = {"aihot-refresh": "aihot", "github-daily": "github", "github-weekly": "github", "projects-daily": "projects"}[plan["key"]]
        agent_id = agent_ids.get(agent_key)
        route = {"key": plan["key"], "runnerKind": plan["runnerKind"], "assigneeAgentId": agent_id, "projectId": project_id or None, "routine": "reuse" if existing else "create", "trigger": "inspect/create", "triggerEnabled": enable_triggers}
        if existing:
            route["routineId"] = existing.get("id")
            route["existingAssigneeAgentId"] = existing.get("assigneeAgentId")
        routes.append(route)
        if not do_apply:
            continue
        if not readable:
            raise PipelineError("Paperclip is not readable; apply requires current routines/agents. " + read_error)
        routine_id = existing.get("id") if existing else None
        if not routine_id:
            created = api.request("POST", f"/api/companies/{company_id}/routines", {
                "projectId": project_id,
                "title": plan["title"], "description": plan["description"],
                "assigneeAgentId": agent_id,
                "priority": "medium", "status": "active",
                "concurrencyPolicy": "coalesce_if_active", "catchUpPolicy": "skip_missed",
            })
            if not isinstance(created, dict) or not created.get("id"):
                raise PipelineError("Paperclip routine create returned no id")
            routine_id = created["id"]
        detail = api.request("GET", f"/api/routines/{routine_id}")
        if detail.get("assigneeAgentId") != agent_id:
            raise PipelineError(f"existing routine assignment for {plan['title']} differs; review/reassign it explicitly before enabling this schedule")
        triggers = detail.get("triggers", []) if isinstance(detail, dict) else []
        trigger = next((t for t in triggers if isinstance(t, dict) and t.get("kind") == "schedule" and t.get("label") == plan["key"]), None)
        if not trigger:
            api.request("POST", f"/api/routines/{routine_id}/triggers", {"kind": "schedule", "label": plan["key"], "cronExpression": plan["cronExpression"], "timezone": plan["timezone"], "enabled": enable_triggers})
        elif bool(trigger.get("enabled")) != enable_triggers:
            trigger_id = trigger.get("id")
            if not trigger_id:
                raise PipelineError(f"existing schedule trigger for {plan['title']} has no ID; cannot set requested enabled state")
            api.request("PATCH", f"/api/routine-triggers/{trigger_id}", {"enabled": enable_triggers})
        route["routineId"] = routine_id
        route["applied"] = True
    prerequisites = []
    if not project_id:
        prerequisites.append("projectId")
    elif project_id not in project_ids:
        prerequisites.append("projectIdInSelectedCompany")
    prerequisites.extend(f"{key}AgentId" for key in ("aihot", "github", "projects") if not agent_ids.get(key))
    return {"mode": "apply" if do_apply else "dry-run", "companyId": company_id, "projectId": project_id or None, "paperclipReadable": readable, "readyToApply": readable and not prerequisites, "missingPrerequisites": prerequisites, "enableTriggers": enable_triggers, "routes": routes, **({"readError": read_error} if not readable else {})}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--company-id", default=os.getenv("PAPERCLIP_COMPANY_ID", ""))
    parser.add_argument("--project-id", default=os.getenv("ORIALIS_NEWS_PAPERCLIP_PROJECT_ID", ""), help="Orialis News operations project ID")
    parser.add_argument("--base-url", default=os.getenv("PAPERCLIP_API_URL", "http://127.0.0.1:3100"))
    parser.add_argument("--aihot-process-agent-id", default=os.getenv("ORIALIS_NEWS_AIHOT_PROCESS_AGENT_ID"))
    parser.add_argument("--github-agent-id", default=os.getenv("ORIALIS_NEWS_GITHUB_AGENT_ID"))
    parser.add_argument("--projects-agent-id", default=os.getenv("ORIALIS_NEWS_PROJECTS_AGENT_ID"))
    parser.add_argument("--enable-triggers", action="store_true", help="create/enable schedule triggers; omitted triggers stay disabled")
    parser.add_argument("--apply", action="store_true", help="create missing routines and schedule triggers")
    args = parser.parse_args(argv)
    if not args.company_id:
        parser.error("--company-id or PAPERCLIP_COMPANY_ID is required")
    try:
        result = apply(args.company_id, {"aihot": args.aihot_process_agent_id or "", "github": args.github_agent_id or "", "projects": args.projects_agent_id or ""}, base_url=args.base_url, token=os.getenv("PAPERCLIP_API_KEY", ""), do_apply=args.apply, project_id=args.project_id, enable_triggers=args.enable_triggers)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except PipelineError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
