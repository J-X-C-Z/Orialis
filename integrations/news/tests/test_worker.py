import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from integrations.news.pipeline import PipelineError, TaskStore
from integrations.news.worker import WorkerApi, WorkerLedger, run_worker


class FakeApi:
    def __init__(self):
        self.run_id = "run-1"
        self.identity = {"id": "agent-1", "companyId": "company-1"}
        self.run = {"id": "run-1", "agentId": "agent-1", "companyId": "company-1", "status": "running", "contextSnapshot": {"issueId": "issue-1", "projectId": "project-1"}}
        self.issue = {"id": "issue-1", "companyId": "company-1", "projectId": "project-1", "assigneeAgentId": "agent-1", "originKind": "routine_execution", "originId": "routine-aihot", "status": "todo"}
        self.mutations = []
        self.fail_done = False

    def get(self, path):
        if path == "/api/agents/me": return dict(self.identity)
        if path.startswith("/api/heartbeat-runs/"): return dict(self.run)
        if path.startswith("/api/issues/"): return dict(self.issue)
        raise AssertionError(path)

    def request(self, method, path, payload):
        self.mutations.append((method, path, payload))
        if method == "PATCH":
            if payload.get("status") == "done" and self.fail_done:
                self.fail_done = False
                raise PipelineError("transient disposition failure")
            self.issue["status"] = payload["status"]
        return dict(self.issue)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = TaskStore(Path(self.temp.name) / "worker.db")
        self.api = FakeApi()
        self.env = {"ORIALIS_NEWS_PAPERCLIP_COMPANY_ID": "company-1", "ORIALIS_NEWS_PAPERCLIP_PROJECT_ID": "project-1", "ORIALIS_NEWS_AIHOT_ROUTINE_ID": "routine-aihot", "ORIALIS_NEWS_GITHUB_DAILY_ROUTINE_ID": "routine-daily", "ORIALIS_NEWS_GITHUB_WEEKLY_ROUTINE_ID": "routine-weekly", "PAPERCLIP_AGENT_ID": "agent-1"}
        self.calls = []

    def tearDown(self): self.temp.cleanup()

    def operation(self, workflow, task_id, store):
        self.calls.append((workflow, task_id))
        return {"taskId": task_id, "status": "succeeded", "published": True}

    def invoke(self, workflow="aihot", operation=None):
        return run_worker(self.api, self.env, workflow, self.store, operation or self.operation)

    def test_success_checks_scope_and_persists_done_with_comment(self):
        result = self.invoke()
        self.assertEqual(result["status"], "done")
        self.assertEqual(self.calls, [("aihot", "paperclip-news-aihot-issue-1")])
        self.assertEqual(self.api.mutations[0][0], "POST")
        self.assertEqual(self.api.mutations[1][2]["status"], "done")
        self.assertIn("taskId=paperclip-news-aihot-issue-1", self.api.mutations[1][2]["comment"])

    def test_cross_company_project_assignee_or_routine_does_no_work_or_mutation(self):
        for field, value in (("companyId", "other"), ("projectId", "other"), ("assigneeAgentId", "other"), ("originId", "other"), ("originKind", "manual")):
            original = self.api.issue[field]
            self.api.issue[field] = value
            with self.subTest(field=field), self.assertRaises(PipelineError): self.invoke()
            self.api.issue[field] = original
        self.assertEqual(self.calls, [])
        self.assertEqual(self.api.mutations, [])

    def test_mismatched_run_and_agent_do_not_mutate(self):
        self.api.run["agentId"] = "other"
        with self.assertRaises(PipelineError): self.invoke()
        self.assertEqual(self.api.mutations, [])

    def test_failed_publication_marks_issue_blocked(self):
        result = self.invoke(operation=lambda *args: {"status": "failed"})
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(self.api.issue["status"], "blocked")
        self.assertNotIn("done", [x[2].get("status") for x in self.api.mutations])

    def test_recovery_only_completes_after_durable_receipt_without_republication(self):
        self.api.fail_done = True
        with self.assertRaises(PipelineError): self.invoke()
        self.api.run["contextSnapshot"]["allowDeliverableWork"] = False
        result = self.invoke()
        self.assertEqual(result["status"], "done")
        self.assertTrue(result["reusedPublication"])
        self.assertEqual(len(self.calls), 1)

    def test_status_only_recovery_without_receipt_never_calls_collector_or_model(self):
        self.api.run["contextSnapshot"]["allowDeliverableWork"] = False
        result = self.invoke()
        self.assertEqual(result["status"], "blocked")
        self.assertEqual(self.calls, [])

    def test_github_daily_and_weekly_are_selected_from_routine_identity(self):
        self.api.issue["originId"] = "routine-weekly"
        result = self.invoke("github")
        self.assertEqual(result["status"], "done")
        self.assertEqual(self.calls[0][0], "github-weekly")

    def test_unknown_running_receipt_blocks_recovery_without_repeated_work(self):
        ledger = WorkerLedger(self.store)
        ledger.begin("issue-1", "aihot")
        self.assertEqual(self.invoke()["status"], "blocked")
        self.assertEqual(self.invoke()["status"], "blocked")
        self.assertEqual(self.calls, [])
        self.assertEqual(ledger.read("issue-1", "aihot")["status"], "running")

    def test_running_github_with_confirmed_outbox_completes_without_model_call(self):
        self.api.issue["originId"] = "routine-daily"
        ledger = WorkerLedger(self.store)
        ledger.begin("issue-1", "github-daily")
        task_id = "paperclip-news-github-daily-issue-1"
        self.store.begin(task_id, "githot.dev", {"publish": True})
        self.store.prepare_publication(task_id, "POST", "/api/v1/news/publish/github/daily", {"taskId": task_id}, {"brief": {"analysisStatus": "complete"}})
        self.store.finish(task_id, "githot.dev", {"brief": {"analysisStatus": "complete"}})
        self.api.run["contextSnapshot"]["allowDeliverableWork"] = False
        result = self.invoke("github")
        self.assertEqual(result["status"], "done")
        self.assertTrue(result["reusedPublication"])
        self.assertEqual(self.calls, [])

    def test_done_issue_does_not_execute_again(self):
        self.invoke()
        self.api.mutations.clear()
        result = self.invoke()
        self.assertTrue(result["reusedDisposition"])
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.api.mutations, [])

    def test_issue_mutations_include_run_audit_header_without_exposing_key(self):
        env = {"PAPERCLIP_API_URL": "http://127.0.0.1:3100", "PAPERCLIP_API_KEY": "test-private-key", "PAPERCLIP_RUN_ID": "run-1"}
        with patch("urllib.request.build_opener") as opener:
            opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"status":"done"}'
            WorkerApi(env).request("PATCH", "/api/issues/issue-1", {"status": "done", "comment": "published"})
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.get_header("X-paperclip-run-id"), "run-1")
        self.assertEqual(request.get_header("Authorization"), "Bearer test-private-key")
