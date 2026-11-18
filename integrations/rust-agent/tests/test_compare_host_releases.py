import copy
import json
from pathlib import Path
import tempfile
import unittest

from compare_host_releases import aggregate, pool


def case(values, cpu, wall, body=10):
    return {"requests": len(values), "failures": 0, "wall_seconds": wall,
            "agent_peak_rss_bytes": 100, "server_peak_rss_bytes": 200,
            "agent_cpu_ms_per_request": cpu, "server_cpu_ms_per_request": cpu,
            "primary_calls": len(values), "auxiliary_calls": 0,
            "primary_request_body_bytes": body * len(values), "auxiliary_request_body_bytes": 0,
            "primary_records": [{"actual_service_ms": 1} for _ in values], "auxiliary_records": [],
            "profile": "base", "workload": "text", "rows": [{"ok": True, "latency_ms": v} for v in values]}


class Reports(unittest.TestCase):
    def test_pool_uses_samples_and_weighted_cpu_not_mean_of_percentiles(self):
        value = pool([case([1], 100, 1), case([2, 3, 4], 4, 1)])
        self.assertEqual(value["p50_ms"], 2)
        self.assertEqual(value["agent_cpu_ms_per_request"], 28)
        self.assertEqual(value["success_per_second"], 2)
        self.assertIsNone(value["mobile_first_delta_p50_ms"])

    def test_versions_and_body_changes_remain_distinct(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            for label, value in [("baseline", case([1, 2], 2, 1)), ("candidate", case([2, 4], 3, 1, body=20))]:
                path = root / "pair-1" / label / "run-1-base"
                path.mkdir(parents=True)
                (path / "text.json").write_text(json.dumps(value))
                (path / "run.json").write_text('{}')
            result, = aggregate(root)
            self.assertEqual(result["candidate_over_baseline"]["p50_ms"], 2)
            self.assertTrue(result["model_call_counts_equal"])
            self.assertFalse(result["mean_body_bytes_equal"])


if __name__ == "__main__":
    unittest.main()
