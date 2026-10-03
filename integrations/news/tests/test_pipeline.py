import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from integrations.news.paperclip_setup import PaperclipApi, apply as apply_paperclip
from integrations.news.pipeline import (
    CommandRunner, HttpClient, PipelineError, TaskStore, compact_reports, execute_task,
    github_readme_api_url, receive_project_report, run_github, run_projects, validate_report,
)


class FakeRunner:
    name = "fake"

    def __init__(self, result=None, fail=False):
        self.result = result or {"repositories": []}
        self.fail = fail
        self.calls = []

    def analyze(self, instruction, facts):
        self.calls.append((instruction, facts))
        if self.fail:
            raise RuntimeError("simulated runner fault")
        return self.result


class FakeBackend(HttpClient):
    def __init__(self):
        super().__init__("http://unused")
        self.calls = []

    def request(self, method, path, payload=None):
        self.calls.append((method, path, payload))
        return {"ok": True}


def secretary(project="Orialis", **overrides):
    value = {"project": project, "date": "2026-10-02", "completed": ["shipped sync"], "in_progress": ["News pipeline"], "decisions": [], "issues": ["feed unavailable"], "next": ["retry feed"], "important": ["News pipeline"]}
    value.update(overrides)
    return value


class NewsPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = TaskStore(Path(self.temp.name) / "news.db")

    def tearDown(self):
        self.temp.cleanup()

    def test_secretary_protocol_is_strict_and_reports_are_idempotent(self):
        with self.assertRaisesRegex(PipelineError, "missing required"):
            validate_report({"project": "Orialis"})
        with self.assertRaisesRegex(PipelineError, "unsupported"):
            validate_report({**secretary(), "codeDiff": "should not be accepted"})
        payload = {"taskId": "secretary-1", "source": "orialis-project-report/orialis-secretary", "projectId": "project-1", "userId": "user-1", "report": secretary()}
        self.assertTrue(receive_project_report(self.store, payload, expected_user_id="user-1")["accepted"])
        self.assertFalse(receive_project_report(self.store, payload, expected_user_id="user-1")["accepted"])
        with self.assertRaisesRegex(PipelineError, "does not match"):
            receive_project_report(self.store, payload, expected_user_id="user-2")

    def test_project_rollup_deduplicates_and_preserves_original_report(self):
        a = secretary()
        b = secretary("Orialis", completed=["shipped sync", "new API"], important=["News pipeline"])
        merged = compact_reports([{"source": "a", "report": a}, {"source": "b", "report": b}], "2026-10-02")
        project = merged["projects"][0]
        self.assertEqual(project["completed"], ["shipped sync", "new API"])
        self.assertEqual(merged["counts"]["issues"], 1)

    def test_runner_timeout_is_bounded_configurable_and_explicit_override_wins(self):
        with patch.dict("os.environ", {"ORIALIS_NEWS_RUNNER_TIMEOUT": "540"}):
            self.assertEqual(CommandRunner("codex exec").timeout, 540)
            self.assertEqual(CommandRunner("codex exec", timeout=240).timeout, 240)
        for value in ("0", "901", "-1", "not-an-integer"):
            with self.subTest(value=value), patch.dict("os.environ", {"ORIALIS_NEWS_RUNNER_TIMEOUT": value}):
                with self.assertRaises(PipelineError):
                    CommandRunner("codex exec")
        with patch.dict("os.environ", {}, clear=True):
            self.assertEqual(CommandRunner("codex exec").timeout, 180)

    def test_command_runner_recovers_complete_json_object_after_cli_preamble(self):
        class Completed:
            returncode = 0
            stderr = ""
            stdout = "分析结果如下：\n```json\n{\"repositories\":[],\"brief\":{\"summary\":\"已核实\"}}\n```\n"
        with patch("integrations.news.pipeline.subprocess.run", return_value=Completed()):
            result = CommandRunner("hermes chat --oneshot").analyze("instruction", {"period": "daily"})
        self.assertEqual(result["brief"]["summary"], "已核实")

    def test_backend_requests_identify_news_worker_for_public_edge(self):
        with patch("integrations.news.pipeline.urllib.request.build_opener") as opener:
            opener.return_value.open.return_value.__enter__.return_value.read.return_value = b'{"ok": true}'
            response = HttpClient("https://orialis.example").request("GET", "/api/health")
        self.assertEqual(response, {"ok": True})
        request = opener.return_value.open.call_args.args[0]
        self.assertEqual(request.get_header("User-agent"), "Orialis-News/0.1")

    def test_empty_github_ranking_never_calls_runner_or_overwrites_published_cache(self):
        backend = FakeBackend()
        runner = FakeRunner()
        task = run_github("daily", self.store, runner, backend, mock_data=[], publish=True, task_id="daily-empty")
        self.assertEqual(task["status"], "failed")
        self.assertEqual(task["phase"], "collection")
        self.assertEqual(runner.calls, [])
        self.assertEqual(backend.calls, [])

    def test_github_publishes_source_copy_without_calling_any_runner(self):
        backend = FakeBackend()
        runner = FakeRunner(fail=True)
        ranks = [{"ranking": 1, "repository": "owner/repo", "sourceTitle": "中文标题", "sourceSummary": "源站原文，不改写。", "sourceTopics": ["agents"], "readme": "# README"}]
        task = run_github("daily", self.store, runner, backend, mock_data=ranks, publish=True, task_id="daily-source-1")
        self.assertEqual(task["status"], "succeeded")
        self.assertEqual(runner.calls, [])
        self.assertFalse(task["result"]["stale"])
        published = backend.calls[0][2]["result"]
        self.assertEqual(published["repositories"][0]["summary"], ranks[0]["sourceSummary"])
        self.assertEqual(published["repositories"][0]["sourceTitle"], ranks[0]["sourceTitle"])
        self.assertEqual(published["repositories"][0]["readme"], ranks[0]["readme"])
        self.assertEqual(published["brief"]["analysisStatus"], "not_required")
        self.assertEqual(published["brief"]["source"], "githot.dev")
        self.assertEqual(published["brief"]["themes"], [])
        self.assertEqual(published["brief"]["highlights"], [])
        self.assertEqual(published["repositories"][0]["sourceTopics"], ["agents"])

    def test_weekly_direct_publication_keeps_every_source_summary(self):
        ranks = [{"ranking": n, "repository": f"owner/repo-{n}", "sourceSummary": f"源站简介 {n}"} for n in range(1, 19)]
        runner = FakeRunner({"repositories": [{"repository": "invented/repo"}]})
        backend = FakeBackend()
        task = run_github("weekly", self.store, runner, backend, mock_data=ranks, publish=True, task_id="weekly-source-1")
        self.assertEqual(task["status"], "succeeded")
        self.assertEqual(runner.calls, [])
        self.assertEqual(len(task["result"]["repositories"]), 18)
        self.assertEqual([x["summary"] for x in task["result"]["repositories"]], [x["sourceSummary"] for x in ranks])
        self.assertEqual(backend.calls[0][1], "/api/v1/news/publish/github/weekly")

    def test_publish_timeout_retries_exact_prepared_payload_without_reanalysis(self):
        class TimeoutAfterAcceptBackend(FakeBackend):
            def __init__(self):
                super().__init__()
                self.fail_once = True
            def request(self, method, path, payload=None):
                self.calls.append((method, path, payload))
                if self.fail_once:
                    self.fail_once = False
                    raise TimeoutError("response lost after server acceptance")
                return {"ok": True}

        backend = TimeoutAfterAcceptBackend()
        ranks = [{"ranking": 1, "repository": "owner/repo", "description": "tool", "stars": 200, "readme": "A test README."}]
        first_runner_output = {"repositories": [{"repository": "owner/repo", "summary": "grounded"}], "brief": {"title": "Daily", "summary": "Grounded overview.", "themes": [], "highlights": []}}
        first = run_github("daily", self.store, FakeRunner(first_runner_output), backend, mock_data=ranks, publish=True, task_id="timeout-1")
        self.assertEqual(first["status"], "failed")
        self.assertEqual(first["phase"], "publish")
        first_payload = backend.calls[0][2]

        second = run_github("daily", self.store, FakeRunner(fail=True), backend, mock_data=[], publish=True, task_id="timeout-1")
        self.assertEqual(second["status"], "succeeded")
        self.assertEqual(backend.calls[1][2], first_payload)
        self.assertEqual(second["result"]["repositories"], first_payload["result"]["repositories"])

    def test_collection_failure_is_distinct_from_analysis_degradation(self):
        with patch("integrations.news.pipeline.collect_github", side_effect=RuntimeError("feed offline")):
            task = run_github("daily", self.store, FakeRunner(), FakeBackend(), task_id="collect-fail-1")
        self.assertEqual(task["status"], "failed")
        self.assertEqual(task["phase"], "collection")

    def test_projects_analysis_failure_keeps_original_reports_and_degrades(self):
        report = secretary()
        self.store.record_report("orialis-project-report/orialis", report, "user-a", "project-a")
        task = run_projects("2026-10-02", self.store, FakeRunner(fail=True), FakeBackend(), project_user_id="user-a", task_id="projects-ai-fail-1")
        self.assertEqual(task["status"], "degraded")
        self.assertEqual(task["phase"], "analysis")
        self.assertEqual(task["result"]["rawReports"][0]["report"], report)

    def test_failed_task_can_retry_same_id_only_with_same_input(self):
        execute_task(self.store, "retry-1", "test", {"x": 1}, lambda: (_ for _ in ()).throw(ValueError("no")))
        result = execute_task(self.store, "retry-1", "test", {"x": 1}, lambda: {"ok": True})
        self.assertEqual(result["status"], "succeeded")
        with self.assertRaisesRegex(PipelineError, "different input"):
            execute_task(self.store, "retry-1", "test", {"x": 2}, lambda: {})

    def test_reports_are_scoped_by_user(self):
        report = secretary()
        self.store.record_report("orialis-project-report/orialis", report, "user-a", "project-a")
        self.store.record_report("orialis-project-report/orialis", report, "user-b", "project-b")
        self.assertEqual(len(self.store.reports("2026-10-02", "user-a")), 1)
        self.assertEqual(self.store.reports("2026-10-02", "user-a")[0]["projectId"], "project-a")
        self.assertEqual(len(self.store.reports("2026-10-02", "user-b")), 1)

    def test_empty_projects_run_is_truthful_and_does_not_call_or_publish(self):
        backend = FakeBackend()
        runner = FakeRunner(fail=True)
        task = run_projects("2026-10-02", self.store, runner, backend, project_user_id="user-a", publish=True, task_id="projects-empty-1")
        self.assertEqual(task["status"], "succeeded")
        self.assertEqual(task["result"]["summaryStatus"], "empty")
        self.assertEqual(task["result"]["projects"], [])
        self.assertEqual(task["result"]["rawReports"], [])
        self.assertEqual(backend.calls, [])

    def test_github_readme_api_url_includes_repository_segment(self):
        self.assertEqual(github_readme_api_url("astral-sh", "uv"), "https://api.github.com/repos/astral-sh/uv/readme")

    def test_paperclip_preview_is_read_only(self):
        def response(method, path, payload=None):
            if path.endswith("/agents"):
                return [{"id": "agent-a", "adapterType": "process"}]
            if path.endswith("/routines"):
                return []
            if path.endswith("/projects"):
                return [{"id": "news-project"}]
            raise AssertionError(f"unexpected request: {method} {path}")
        with patch.object(PaperclipApi, "request", side_effect=response) as request:
            result = apply_paperclip("company-1", {"aihot": "", "github": "", "projects": ""}, base_url="http://paperclip", token="", do_apply=False)
        self.assertEqual(result["mode"], "dry-run")
        self.assertEqual(len(result["routes"]), 4)
        self.assertTrue(all(call.args[0] == "GET" for call in request.call_args_list))

    def test_paperclip_apply_uses_real_routine_and_schedule_trigger_routes(self):
        calls = []
        routine_agents = {}
        def response(method, path, payload=None):
            calls.append((method, path, payload))
            if path.endswith("/projects"):
                return [{"id": "news-project"}]
            if path.endswith("/agents"):
                return [
                    {"id": "aihot", "adapterType": "process", "adapterConfig": {"command": "python3", "args": ["scripts/news_sources.py", "--refresh", "aihot"]}},
                    {"id": "github", "adapterType": "codex_local"},
                    {"id": "projects", "adapterType": "codex_local"},
                ]
            if path.endswith("/routines") and method == "GET":
                return []
            if path.endswith("/routines") and method == "POST":
                routine_id = f"routine-{len(routine_agents) + 1}"
                routine_agents[routine_id] = payload["assigneeAgentId"]
                return {"id": routine_id}
            if path.startswith("/api/routines/") and path.endswith("/triggers"):
                return {"id": "trigger-1"}
            if path.startswith("/api/routines/"):
                routine_id = path.rsplit("/", 1)[-1]
                return {"id": routine_id, "assigneeAgentId": routine_agents[routine_id], "triggers": []}
            raise AssertionError(f"unexpected request: {method} {path}")
        with patch.object(PaperclipApi, "request", side_effect=response):
            result = apply_paperclip("company-1", {"aihot": "aihot", "github": "github", "projects": "projects"}, base_url="http://paperclip", token="", do_apply=True, project_id="news-project")
        trigger_calls = [(path, payload) for method, path, payload in calls if method == "POST" and path.endswith("/triggers")]
        self.assertEqual(len(trigger_calls), 4)
        self.assertEqual(sum(1 for method, path, _ in calls if method == "POST" and path.endswith("/routines")), 4)
        self.assertTrue(all(route["applied"] for route in result["routes"]))
        self.assertIn(("/api/routines/routine-1/triggers", {"kind": "schedule", "label": "aihot-refresh", "cronExpression": "*/5 * * * *", "timezone": "Asia/Shanghai", "enabled": False}), trigger_calls)

    def test_paperclip_apply_requires_existing_scoped_project_before_writes(self):
        calls = []
        def response(method, path, payload=None):
            calls.append((method, path, payload))
            if path.endswith("/agents"):
                return [
                    {"id": "aihot", "adapterType": "process", "adapterConfig": {"args": ["scripts/news_sources.py", "--refresh", "aihot"]}},
                    {"id": "github", "adapterType": "codex_local"},
                    {"id": "projects", "adapterType": "codex_local"},
                ]
            if path.endswith("/routines"):
                return []
            if path.endswith("/projects"):
                return [{"id": "other-project"}]
            raise AssertionError(f"unexpected request: {method} {path}")
        with patch.object(PaperclipApi, "request", side_effect=response):
            with self.assertRaisesRegex(PipelineError, "not in the selected Paperclip company"):
                apply_paperclip("company-1", {"aihot": "aihot", "github": "github", "projects": "projects"}, base_url="http://paperclip", token="", do_apply=True, project_id="news-project")
        self.assertTrue(all(method == "GET" for method, _, _ in calls))


if __name__ == "__main__":
    unittest.main()
