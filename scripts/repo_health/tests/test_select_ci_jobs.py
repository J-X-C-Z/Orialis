import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.repo_health.select_ci_jobs import event_range, git_changed_paths, select_jobs


class EventRangeTests(unittest.TestCase):
    def test_pull_request_requires_both_shas(self):
        event = {"pull_request": {"base": {"sha": "a" * 40}, "head": {"sha": "b" * 40}}}
        self.assertEqual(event_range("pull_request", event), ("a" * 40, "b" * 40))

    def test_push_checks_event_sha(self):
        event = {"before": "a" * 40, "after": "b" * 40}
        self.assertEqual(event_range("push", event, "b" * 40), ("a" * 40, "b" * 40))
        with self.assertRaisesRegex(ValueError, "does not match"):
            event_range("push", event, "c" * 40)

    def test_missing_and_unsupported_events_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "missing before/after"):
            event_range("push", {})
        with self.assertRaisesRegex(ValueError, "unsupported event"):
            event_range("workflow_dispatch", {})


class ChangedPathSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "ci-fixture@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "CI fixture"], cwd=self.root, check=True)

    def tearDown(self):
        self.temp.cleanup()

    def commit(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-qm", name], cwd=self.root, check=True)
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.root, check=True,
                              text=True, capture_output=True).stdout.strip()

    def test_push_range_resolves_only_changed_consumer(self):
        base = self.commit("README.md", "base")
        head = self.commit("website/src/main.ts", "changed")
        paths = git_changed_paths(self.root, base, head)
        selected = select_jobs(paths)
        self.assertTrue(selected["website"])
        self.assertFalse(selected["rust"])
        self.assertFalse(selected["mobile"])

    def test_shared_contract_runs_all_declared_consumers(self):
        selected = select_jobs(["protocol/contracts/fixtures/task-v1.json"])
        self.assertTrue(selected["rust"])
        self.assertTrue(selected["contracts"])
        self.assertTrue(selected["python"])
        self.assertTrue(selected["mobile"])
        self.assertTrue(selected["macos_client"])
        self.assertTrue(selected["vela"])

    def test_shared_contract_lock_and_flutter_config_route_consumers(self):
        contract_lock = select_jobs(["protocol/contracts/fixtures/task-v1.json"])
        self.assertTrue(contract_lock["contracts"])
        self.assertTrue(contract_lock["python"])
        self.assertTrue(contract_lock["rust"])
        self.assertTrue(contract_lock["mobile"])
        self.assertTrue(contract_lock["macos_client"])
        self.assertTrue(contract_lock["vela"])

        flutter_config = select_jobs(["mobile/pubspec.lock"])
        self.assertTrue(flutter_config["mobile"])
        self.assertTrue(flutter_config["macos_client"])

    def test_workflow_change_runs_every_component_job(self):
        selected = select_jobs([".github/workflows/ci.yml"])
        self.assertTrue(all(selected.values()))

    def test_lockfiles_select_their_exact_consumers(self):
        website = select_jobs(["website/package-lock.json"])
        self.assertTrue(website["website"])
        self.assertFalse(website["lumina_web"])
        rust = select_jobs(["Cargo.lock"])
        self.assertTrue(rust["rust"])
        self.assertFalse(rust["mobile"])
        flutter = select_jobs(["mobile/pubspec.lock"])
        self.assertTrue(flutter["mobile"])
        self.assertTrue(flutter["macos_client"])
        vela = select_jobs(["band/vela/package-lock.json"])
        self.assertTrue(vela["vela"])
        self.assertFalse(vela["website"])
        lumina_web = select_jobs(["packages/lumina_web/package-lock.json"])
        self.assertTrue(lumina_web["lumina_web"])
        self.assertFalse(lumina_web["website"])

    def test_shared_token_changes_select_every_consumer(self):
        selected = select_jobs(["packages/lumina_tokens/source/tokens.json"])
        self.assertTrue(selected["mobile"])
        self.assertTrue(selected["macos_client"])
        self.assertTrue(selected["lumina_flutter"])
        self.assertTrue(selected["lumina_web"])

    def test_root_isolated_roadmap_suite_selects_python_and_rust(self):
        selected = select_jobs(["tests/roadmap/test_live_api.py"])
        self.assertTrue(selected["python"])
        self.assertTrue(selected["rust"])
        selected_script = select_jobs(["scripts/roadmap-e2e/run.py"])
        self.assertTrue(selected_script["python"])
        self.assertTrue(selected_script["rust"])

    def test_clippy_gate_inputs_select_rust(self):
        for path in ("scripts/repo_health/clippy_diagnostics.py",
                     ".github/repo-health/clippy-baseline.json"):
            with self.subTest(path=path):
                self.assertTrue(select_jobs([path])["rust"])


if __name__ == "__main__":
    unittest.main()
