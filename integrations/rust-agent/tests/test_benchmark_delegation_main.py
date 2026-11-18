"""Pure fixture/measurement checks. Never starts an Agent, Server or benchmark."""
import json
import unittest

import benchmark_delegation_main as bench


class MeasurementTests(unittest.TestCase):
    def test_nearest_rank_and_empty_samples(self):
        self.assertIsNone(bench.quantile([], .99))
        values = list(range(1, 31))
        self.assertEqual(bench.quantile(values, .5), 15)
        self.assertEqual(bench.quantile(values, .95), 29)
        self.assertEqual(bench.quantile(values, .99), 30)

    def test_interval_union_does_not_double_count_parallel_children(self):
        self.assertEqual(bench.union_seconds([]), 0)
        self.assertAlmostEqual(bench.union_seconds([(1, 1.020), (1.001, 1.021), (1.03, 1.032)]), .023)
        self.assertAlmostEqual(bench.union_seconds([(0, 5), (1, 2), (5, 6)]), 6)

    def test_parent_child_structure_and_isolation(self):
        parent = {"messages": [{"role": "system", "content": "parent"},
                               {"role": "user", "content": "DELEGATEBENCH:r1-1:END PARENT_PRIVATE_MARKER"}],
                  "tools": [{"function": {"name": "delegate_task"}}]}
        key, stage, message = bench.scripted_reply(parent)
        self.assertEqual((key, stage), ("r1-1", "parent_delegate"))
        tasks = json.loads(message["tool_calls"][0]["function"]["arguments"])["tasks"]
        self.assertEqual(len(tasks), 2)
        outcomes = []
        for side, task in zip(["left", "right"], tasks):
            payload = {"messages": [{"role": "system", "content": "You are an isolated delegated assistant."},
                                    {"role": "user", "content": task["goal"] + "\n" + task["context"]}], "tools": []}
            _, child_stage, answer = bench.scripted_reply(payload)
            self.assertEqual(child_stage, "child_" + side)
            outcomes.append({"summary": answer["content"], "subagent_id": side})
            payload["messages"][1]["content"] += " PARENT_PRIVATE_MARKER"
            with self.assertRaises(AssertionError):
                bench.scripted_reply(payload)
        parent["messages"] += [message, {"role": "tool", "content": json.dumps({"mode": "inline", "partial": False, "results": outcomes})}]
        _, stage, final = bench.scripted_reply(parent)
        self.assertEqual(stage, "parent_final")
        self.assertEqual(final["content"], "DELEGATION_BENCH_OK_r1-1")

    def test_stream_body_preserves_tool_call_index_and_final_sentinel(self):
        message = {"role": "assistant", "content": None, "tool_calls": [{"id": "call", "type": "function", "function": {"name": "delegate_task", "arguments": "{}"}}]}
        body = bench.response_body(message, True).decode()
        events = [line[6:] for line in body.splitlines() if line.startswith("data: ")]
        self.assertEqual(events[-1], "[DONE]")
        self.assertEqual(json.loads(events[0])["choices"][0]["delta"]["tool_calls"][0]["index"], 0)
        self.assertEqual(json.loads(events[1])["choices"][0]["finish_reason"], "tool_calls")
        plain = json.loads(bench.response_body(message, False))
        self.assertEqual(plain["choices"][0]["message"], message)

    def test_per_user_metrics_count_actual_calls_and_bodies(self):
        calls = []
        for stage, start, end in [("parent_delegate", .001, .002), ("child_left", .003, .023),
                                  ("child_right", .004, .024), ("parent_final", .025, .026)]:
            calls.append({"stage": stage, "received_s": start, "response_queued_s": end,
                          "request_body_bytes": 10, "response_body_bytes": 20,
                          "service_ms": (end - start) * 1000, "actual_delay_ms": 20 if stage.startswith("child") else 0})
        metrics = bench.call_metrics(calls, {"submitted_s": 0, "latency_ms": 30})
        self.assertEqual(metrics["parent_calls"], 2)
        self.assertEqual(metrics["child_calls"], 2)
        self.assertEqual(metrics["child_request_body_bytes"], 20)
        self.assertEqual(metrics["parent_response_body_bytes"], 40)
        self.assertAlmostEqual(metrics["provider_union_ms"], 23)
        self.assertAlmostEqual(metrics["child_model_span_ms"], 21)
        self.assertAlmostEqual(metrics["child_model_overlap_ms"], 19)
        self.assertAlmostEqual(metrics["e2e_minus_provider_union_ms"], 7)
        with self.assertRaises(AssertionError):
            bench.call_metrics(calls + calls[:1], {"submitted_s": 0, "latency_ms": 30})

    def test_process_metrics_disclose_sampled_rss_and_cpu_wall_ratio(self):
        before = {"cpu_seconds": 1., "rss_bytes": 10, "threads": 2}
        after = {"cpu_seconds": 1.2, "rss_bytes": 15, "threads": 3}
        sample = {"cpu_seconds": 1.1, "rss_bytes": 25, "threads": 4}
        result = bench.process_metrics(before, after, [sample], 10, .5)
        self.assertAlmostEqual(result["cpu_ms_per_request"], 20)
        self.assertAlmostEqual(result["cpu_percent_of_one_core"], 40)
        self.assertEqual(result["sampled_peak_rss_bytes"], 25)
        self.assertEqual(result["max_threads"], 4)


if __name__ == "__main__":
    unittest.main()
