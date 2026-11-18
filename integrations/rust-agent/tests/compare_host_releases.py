#!/usr/bin/env python3
"""Paired, alternating release regression measurement using the real Server.

This does not benchmark newly opt-in tools themselves. It detects changes to the
existing base/full feature envelope while running identical fixture workloads.
Every sample is produced by benchmark_integrated_profile.py in a fresh process.
"""
import argparse
import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path

HARNESS = Path(__file__).with_name("benchmark_integrated_profile.py")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def quantile(values, q):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * q) - 1)] if values else None


def pool(cases):
    count = sum(c["requests"] for c in cases)
    values = [r["latency_ms"] for c in cases for r in c["rows"] if r["ok"]]
    wall = sum(c["wall_seconds"] for c in cases)
    result = {
        "requests": count, "failures": sum(c["failures"] for c in cases),
        "p50_ms": quantile(values, .5), "p95_ms": quantile(values, .95),
        "p99_ms": quantile(values, .99), "success_per_second": len(values) / wall,
        "agent_peak_rss_bytes": max(c["agent_peak_rss_bytes"] for c in cases),
        "server_peak_rss_bytes": max(c["server_peak_rss_bytes"] for c in cases),
    }
    for key in ("agent_cpu_ms_per_request", "server_cpu_ms_per_request"):
        result[key] = sum(c[key] * c["requests"] for c in cases) / count
    for prefix in ("primary", "auxiliary"):
        result[prefix + "_calls_per_request"] = sum(c[prefix + "_calls"] for c in cases) / count
        result[prefix + "_body_bytes_per_request"] = sum(c[prefix + "_request_body_bytes"] for c in cases) / count
        records = [r for c in cases for r in c[prefix + "_records"]]
        result[prefix + "_actual_service_p50_ms"] = quantile([r["actual_service_ms"] for r in records], .5)
    for field in ("mobile_final_ms", "mobile_first_delta_ms"):
        result[field.replace("_ms", "_p50_ms")] = quantile([r[field] for c in cases for r in c["rows"] if field in r], .5)
    return result


def aggregate(root):
    grouped = {}
    for path in root.glob("pair-*/**/*.json"):
        if path.name in ("summary.json", "run.json"):
            continue
        value = json.loads(path.read_text())
        if not isinstance(value, dict) or not {"rows", "requests", "workload", "profile"}.issubset(value):
            continue
        implementation = path.parts[len(root.parts) + 1]
        grouped.setdefault((implementation, value["profile"], value["workload"]), []).append(value)
    result = []
    for profile, workload in sorted({(p, w) for _, p, w in grouped}):
        a = pool(grouped[("baseline", profile, workload)])
        b = pool(grouped[("candidate", profile, workload)])
        ratios = {field: (b[field] / a[field] if a[field] else None) for field in
                  ("p50_ms", "p95_ms", "p99_ms", "success_per_second", "agent_cpu_ms_per_request", "agent_peak_rss_bytes")}
        body_fields = ("primary_body_bytes_per_request", "auxiliary_body_bytes_per_request")
        call_fields = ("primary_calls_per_request", "auxiliary_calls_per_request")
        result.append({"profile": profile, "workload": workload, "baseline": a, "candidate": b,
                       "candidate_over_baseline": ratios,
                       "model_call_counts_equal": all(a[k] == b[k] for k in call_fields),
                       "mean_body_bytes_equal": all(a[k] == b[k] for k in body_fields)})
    return result


def main(args):
    args.out.mkdir(parents=True, exist_ok=False)
    identities = {key: {"path": str(path.resolve()), "sha256": sha(path)} for key, path in
                  (("baseline", args.baseline), ("candidate", args.candidate), ("server", args.server), ("harness", HARNESS))}
    identities["driver"] = {"path": str(Path(__file__).resolve()), "sha256": sha(Path(__file__))}
    (args.out / "identities.json").write_text(json.dumps(identities, indent=2) + "\n")
    runs = []
    for pair in range(args.pairs):
        order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
        for label in order:
            for key, info in identities.items():
                if sha(Path(info["path"])) != info["sha256"]:
                    raise RuntimeError(f"{key} changed during measurement; stop, do not mix versions")
            destination = args.out / f"pair-{pair+1}" / label
            destination.parent.mkdir(exist_ok=True)
            command = [sys.executable, str(HARNESS), "--binary", str(getattr(args, label)),
                       "--server", str(args.server), "--server-variant", args.server_variant,
                       "--out", str(destination), "--trials", "1", "--iterations", str(args.iterations),
                       "--deep-iterations", str(args.deep_iterations), "--model-delay-ms", str(args.model_delay_ms),
                       "--profiles", *args.profiles, "--workloads", *args.workloads]
            runs.append({"pair": pair+1, "implementation": label, "command": command})
            (args.out / "runs.json").write_text(json.dumps(runs, indent=2) + "\n")
            with (destination.parent / f"{label}.log").open("w") as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1800)
            report = json.loads((destination / "summary.json").read_text())
            assert report["binary_sha256"] == identities[label]["sha256"]
            assert report["server_binary_sha256"] == identities["server"]["sha256"]
            print(f"pair {pair+1}: {label} complete", flush=True)
    for key, info in identities.items():
        assert sha(Path(info["path"])) == info["sha256"], f"{key} changed"
    report = {"identities": identities, "order": runs, "summary": aggregate(args.out),
              "scope": "Release regression in the same existing base/full configuration; new opt-in tools require separate workload tests.",
              "limitations": ["Shared executor; no CPU pinning or isolation, no confidence intervals.",
                              "Alternating order reduces but does not remove time-dependent noise.",
                              "Additional schemas can change request size even with identical configuration flags; check body/call fields.",
                              "Synthetic model, account and mobile WS observer; no Flutter rendering, WAN/TLS or answer-quality claim.",
                              "CPU includes reaped children; 20ms RSS sampling can miss short processes; RSS is not proportional memory.",
                              "Caller must arrange a quiet window; this driver cannot prove absence of unrelated host work."]}
    (args.out / "comparison.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report["summary"], indent=2))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    for key in ("baseline", "candidate", "server", "out"):
        p.add_argument("--" + key, type=Path, required=True)
    p.add_argument("--server-variant", required=True)
    p.add_argument("--pairs", type=int, default=3)
    p.add_argument("--iterations", type=int, default=40)
    p.add_argument("--deep-iterations", type=int, default=20)
    p.add_argument("--model-delay-ms", type=float, default=20)
    p.add_argument("--profiles", nargs="+", choices=["base", "full"], default=["base", "full"])
    p.add_argument("--workloads", nargs="+", choices=["short", "tools", "history"], default=["short", "tools", "history"])
    a = p.parse_args()
    assert 1 <= a.pairs <= 20 and 1 <= a.iterations <= 10000 and 1 <= a.deep_iterations <= 10000
    main(a)
