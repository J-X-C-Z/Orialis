#!/usr/bin/env python3
"""Own-child RSS/actor snapshots and request segments using the integrated harness.

The detailed snapshots happen before measured workloads, at warm-idle entry/exit.
No ptrace, perf, global process scan, sandbox changes, or production accounts.
All missing observations stay null with an error. Do not mix memory-map reads into
latency sampling. Arrange a quiet window before invoking run/compare.
"""
import argparse
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("integrated", HERE / "benchmark_integrated_profile.py")
integrated = importlib.util.module_from_spec(spec)
spec.loader.exec_module(integrated)


def safe_read(path):
    try:
        return {"value": path.read_text(), "error": None}
    except (OSError, UnicodeError) as error:
        return {"value": None, "error": str(error)}


def map_category(path, executable):
    if path == executable:
        return "executable"
    if path == "[heap]":
        return "heap"
    if path.startswith("[stack"):
        return "stack"
    if path in ("", "[anon]") or path.startswith("[anon:"):
        return "anonymous"
    if path.endswith("-shm"):
        return "sqlite_shared_memory"
    if ".so" in Path(path).name:
        return "shared_library"
    if path.startswith("["):
        return "kernel_special"
    return "other_file"


def inspect_owned(pid, owned_roots):
    if pid not in owned_roots:
        raise RuntimeError("only directly launched benchmark process roots may be inspected")
    process = integrated.psutil.Process(pid)
    errors = []
    executable = process.exe()
    maps = None
    categories = None
    try:
        maps = []
        categories = {}
        for mapping in process.memory_maps(grouped=False):
            item = mapping._asdict()
            category = map_category(item["path"], executable)
            item["category"] = category
            maps.append(item)
            totals = categories.setdefault(category, {})
            for key in ("rss", "pss", "private_clean", "private_dirty", "shared_clean", "shared_dirty", "anonymous", "size"):
                if key in item:
                    totals[key] = totals.get(key, 0) + item[key]
    except (OSError, integrated.psutil.Error) as error:
        errors.append("memory_maps: " + str(error))
    tasks = []
    try:
        for path in sorted(Path(f"/proc/{pid}/task").iterdir()):
            tasks.append({"tid": int(path.name), "name": safe_read(path / "comm"),
                          "schedstat": safe_read(path / "schedstat"),
                          "wchan": safe_read(path / "wchan"),
                          "status": safe_read(path / "status")})
    except OSError as error:
        errors.append("tasks: " + str(error))
    fds = []
    try:
        for path in sorted(Path(f"/proc/{pid}/fd").iterdir()):
            try:
                fds.append({"fd": int(path.name), "target": os.readlink(path), "error": None})
            except OSError as error:
                fds.append({"fd": int(path.name), "target": None, "error": str(error)})
    except OSError as error:
        errors.append("fds: " + str(error))
    return {"pid": pid, "executable": executable, "captured_monotonic_s": time.perf_counter(),
            "memory_maps": maps, "memory_categories": categories, "tasks": tasks, "fds": fds,
            "children": [child.pid for child in process.children(recursive=True)], "errors": errors}


def request_segments(root):
    grouped = {}
    for path in sorted(root.glob("trial-*/*.json")):
        case = json.loads(path.read_text())
        if not isinstance(case, dict) or "rows" not in case:
            continue
        records = {}
        for record in case["primary_records"]:
            records.setdefault(record["marker"], []).append(record)
        rows = []
        for row in case["rows"]:
            observation = row.get("observations", {})
            calls = records.get(row["marker"], [])
            final_model = max((r["response_queued_s"] for r in calls), default=None)
            mobile = observation.get("mobile_final_s")
            http = observation.get("http_final_s")
            rows.append({"marker": row["marker"], "ok": row["ok"],
                         **{key: row.get(key) for key in ("latency_ms", "submit_to_primary_ms", "primary_actual_total_ms", "mobile_final_ms", "mobile_first_delta_ms")},
                         "model_finish_to_mobile_ms": None if mobile is None or final_model is None else (mobile - final_model) * 1000,
                         "mobile_to_http_observation_ms": None if mobile is None or http is None else (http - mobile) * 1000})
        grouped.setdefault((case["profile"], case["workload"]), []).extend(rows)
    result = []
    for (profile, workload), rows in sorted(grouped.items()):
        fields = [key for key in rows[0] if key.endswith("_ms")]
        summaries = {}
        for field in fields:
            values = [row[field] for row in rows if row["ok"] and row[field] is not None]
            summaries[field] = {"observed": len(values), "missing": len(rows) - len(values),
                                **{f"p{int(q*100)}": integrated.quantile(values, q) for q in (.5, .95, .99)}}
        result.append({"profile": profile, "workload": workload, "rows": rows, "segments": summaries})
    return result


async def run(args):
    owned_roots = set()
    popen = integrated.subprocess.Popen
    basic_snapshot = integrated.snapshot
    counts = {}
    snapshots = []

    def own_popen(*positional, **keywords):
        child = popen(*positional, **keywords)
        owned_roots.add(child.pid)
        return child

    def snapshot(pid):
        result = basic_snapshot(pid)
        counts[pid] = counts.get(pid, 0) + 1
        # The first two Agent snapshots straddle the warm-idle window.
        # Server's first snapshot is before the first measured workload.
        executable = integrated.psutil.Process(pid).exe()
        is_agent = Path(executable) == args.binary.resolve()
        if args.proc_detail and ((is_agent and counts[pid] <= 2) or (not is_agent and counts[pid] == 1)):
            detail = inspect_owned(pid, owned_roots)
            detail.update(role="agent" if is_agent else "server", phase="warm_idle_before" if counts[pid] == 1 else "warm_idle_after")
            snapshots.append(detail)
            (args.out / "own-processes.json").write_text(json.dumps(snapshots, indent=2) + "\n")
        return result

    integrated.subprocess.Popen = own_popen
    integrated.snapshot = snapshot
    try:
        await integrated.main(args)
    finally:
        integrated.subprocess.Popen = popen
        integrated.snapshot = basic_snapshot
    report = {"driver_sha256": integrated.sha(Path(__file__)), "integrated_harness_sha256": integrated.sha(HERE / "benchmark_integrated_profile.py"),
              "detailed_snapshots": args.proc_detail, "segments": request_segments(args.out),
              "limitations": ["Segment percentiles are separately pooled, never additive or causal CPU attribution.",
                              "Own process RSS maps split code/file/anonymous pages, not allocations by function.",
                              "The nominal model sleep and Python driver remain shared-host scheduling dependent.",
                              "The warm-idle snapshots intentionally precede measured request batches."]}
    (args.out / "regression-segments.json").write_text(json.dumps(report, indent=2) + "\n")


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ("binary", "server", "out"):
        p.add_argument("--" + key, type=Path, required=True)
    p.add_argument("--server-variant", default="control-responsive")
    p.add_argument("--iterations", type=int, default=80)
    p.add_argument("--trials", type=int, default=1)
    p.add_argument("--model-delay-ms", type=float, default=20)
    p.add_argument("--idle-seconds", type=float, default=2)
    p.add_argument("--proc-detail", action="store_true")
    p.add_argument("--profiles", nargs="+", choices=["base", "full"], default=["base", "full"])
    p.set_defaults(auxiliary_delay_ms=2, deep_iterations=20, history_documents=8,
                   pdf_fixture=HERE / "fixtures/profiling/history-2pages.pdf", workloads=["short"])
    return p


if __name__ == "__main__":
    a = parser().parse_args()
    assert a.iterations > 0 and a.trials > 0 and a.idle_seconds >= 0
    asyncio.run(run(a))
