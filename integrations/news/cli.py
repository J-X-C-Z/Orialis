from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys

from .pipeline import (
    CommandRunner, HttpClient, PipelineError, TaskStore, execute_task,
    receive_project_report, retry_pending_publication, run_github, run_projects,
    submit_prepared_publication,
)
from .paperclip_setup import PaperclipApi


def read_json(path: str) -> object:
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PipelineError(f"cannot read JSON input: {type(exc).__name__}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="orialis-news")
    subs = parser.add_subparsers(dest="command", required=True)
    github = subs.add_parser("github")
    github.add_argument("period", choices=("daily", "weekly"))
    github.add_argument("--task-id")
    github.add_argument("--publish", action="store_true")
    projects = subs.add_parser("projects")
    project_sub = projects.add_subparsers(dest="projects_command", required=True)
    ingest = project_sub.add_parser("receive")
    ingest.add_argument("report_json")
    daily = project_sub.add_parser("daily")
    daily.add_argument("date")
    daily.add_argument("--task-id")
    daily.add_argument("--publish", action="store_true")
    paperclip = subs.add_parser("paperclip")
    pc_sub = paperclip.add_subparsers(dest="paperclip_command", required=True)
    plan = pc_sub.add_parser("read-plan")
    plan.add_argument("issue_id")
    routine = pc_sub.add_parser("run-routine")
    routine.add_argument("routine_id")
    routine.add_argument("payload_json", help="JSON object passed as the Paperclip routine run payload")
    args = parser.parse_args(argv)
    store = TaskStore()
    backend = HttpClient()
    try:
        if args.command == "github":
            result = run_github(args.period, store, CommandRunner(), backend, task_id=args.task_id, publish=args.publish)
        elif args.command == "projects" and args.projects_command == "receive":
            body = read_json(args.report_json)
            expected_user = os.getenv("ORIALIS_NEWS_PROJECT_USER_ID", "")
            if not expected_user:
                raise PipelineError("ORIALIS_NEWS_PROJECT_USER_ID is required to bind secretary reports to a user")
            source = body.get("source", "secretary-report") if isinstance(body, dict) else "secretary-report"
            task_id = body.get("taskId", "") if isinstance(body, dict) else ""
            if not isinstance(task_id, str) or not task_id.strip():
                raise PipelineError("report taskId is required for audit")
            result = retry_pending_publication(store, backend, task_id, source)
            if result is None:
                def accept_and_publish():
                    received = receive_project_report(store, body, expected_user_id=expected_user)
                    remote = {k: body[k] for k in ("taskId", "source", "projectId", "userId")}
                    remote.update({"generatedAt": received["receivedAt"], "period": "daily", "reportDate": received["report"]["date"], "result": received["report"], "idempotencyKey": body["taskId"]})
                    if not backend.token:
                        raise PipelineError("ORIALIS_NEWS_API_TOKEN is required for report publish")
                    submit_prepared_publication(store, backend, task_id, "/api/v1/news/projects/publish", remote, received)
                    return received
                result = execute_task(store, task_id, source, body, accept_and_publish)
        elif args.command == "projects":
            result = run_projects(args.date, store, CommandRunner(), backend, project_user_id=os.getenv("ORIALIS_NEWS_PROJECT_USER_ID"), publish=args.publish, task_id=args.task_id)
        elif args.command == "paperclip" and args.paperclip_command == "read-plan":
            api = PaperclipApi(os.getenv("PAPERCLIP_API_URL", "http://127.0.0.1:3100"), os.getenv("PAPERCLIP_API_KEY", ""))
            result = api.request("GET", f"/api/issues/{args.issue_id}/documents/plan")
        else:
            payload = read_json(args.payload_json)
            if not isinstance(payload, dict):
                raise PipelineError("routine payload must be a JSON object")
            payload.setdefault("source", "api")
            api = PaperclipApi(os.getenv("PAPERCLIP_API_URL", "http://127.0.0.1:3100"), os.getenv("PAPERCLIP_API_KEY", ""))
            result = api.request("POST", f"/api/routines/{args.routine_id}/run", payload)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if not (isinstance(result, dict) and result.get("status") == "failed") else 2
    except PipelineError as exc:
        print(json.dumps({"error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
