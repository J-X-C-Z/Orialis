import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
import json

spec = importlib.util.spec_from_file_location("bench_profile_sync", Path(__file__).parents[1] / "scripts" / "bench_profile_sync.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class ProfileSyncBenchmarkTests(unittest.TestCase):
    def test_balanced_independent_trial_plan(self):
        plan = list(bench.trial_plan(4, [10, 100, 1000]))
        self.assertEqual(len(plan), 24)
        for count in [10, 100, 1000]:
            for implementation in ["native", "python"]:
                positions = [r["position"] for r in plan if r["skill_files"] == count and r["implementation"] == implementation]
                self.assertEqual(positions.count(1), 2)
                self.assertEqual(positions.count(2), 2)
        self.assertEqual([r["implementation"] for r in plan[:2]], ["native", "python"])
        self.assertEqual([r["implementation"] for r in plan[6:8]], ["python", "native"])
        with self.assertRaises(ValueError):
            list(bench.trial_plan(3, [10]))

    def test_nearest_rank_does_not_average_trial_quantiles(self):
        self.assertEqual(bench.quantile(list(range(1, 21)), .95), 19)
        rows = [dict(implementation="native", skill_files=10, operation="idle", trial=trial,
                     wall_ms=value, user_seconds=.001, system_seconds=.002, peak_rss_kib=100)
                for trial, values in [(1, [1]), (2, [2, 3, 4, 100])] for value in values]
        summary = bench.summarize(rows)[0]
        self.assertEqual((summary["samples"], summary["trials"], summary["p50_wall_ms"], summary["p95_wall_ms"]), (5, 2, 3, 100))

    def test_exact_counter_checks_reject_false_success(self):
        valid = {"node": "b", "revision": 12, "applied": 1, "files": 100, "conflicts": []}
        bench.verify_counters(valid, "b", 12, 1, 100)
        for field, value in [("node", "a"), ("revision", 11), ("applied", 0), ("files", 101), ("conflicts", ["skills/stale.md"])]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                bench.verify_counters({**valid, field: value}, "b", 12, 1, 100)

    def test_full_fixture_lifecycle_checks_add_change_delete_and_no_resurrection(self):
        hub = {"files": {}, "revision": 0}
        rows = []
        def simulated_cli(argv, timeout):
            config = json.loads(Path(argv[-1]).read_text())
            profile = Path(config["profile"])
            current = {p.relative_to(profile).as_posix(): p.read_bytes() for p in profile.rglob("*") if p.is_file()}
            if config["node"] == "a" and current != hub["files"]:
                hub["files"], hub["revision"] = current, hub["revision"] + 1
            applied = 0
            if config["node"] == "b":
                for name in set(current) | set(hub["files"]):
                    if current.get(name) == hub["files"].get(name):
                        continue
                    applied += 1
                    path = profile / name
                    if name in hub["files"]:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_bytes(hub["files"][name])
                    else:
                        path.unlink()
            return {"wall_ms": 0, "peak_rss_kib": 0, "user_seconds": 0, "system_seconds": 0,
                    "counters": {"node": config["node"], "revision": hub["revision"], "files": len(hub["files"]), "applied": applied, "conflicts": []}}
        with patch.object(bench, "run_cli", simulated_cli):
            bench.benchmark(["not-executed"], 2, 64, 2, 1, rows.append)
        self.assertEqual(len(rows), 16)
        self.assertEqual({r["operation"] for r in rows}, {
            "bootstrap_publish", "bootstrap_pull", "idle", "one_file_add_publish", "one_file_add_pull",
            "one_file_publish", "one_file_pull", "offline_delete_publish", "offline_delete_catchup", "post_delete_idle"})
        self.assertNotIn("skills/skill-000000.md", hub["files"])
        self.assertEqual(hub["revision"], 6)
        self.assertTrue(all(r["validated"] for r in rows))


if __name__ == "__main__":
    unittest.main()
