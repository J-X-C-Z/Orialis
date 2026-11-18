#!/usr/bin/env python3
"""Alternating frozen final-vs-host-runtime regression; run only in a quiet window.

Retains every sample, nominal delay group and order. Does not build or edit code.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

from compare_host_releases import aggregate

HERE = Path(__file__).resolve().parent
HARNESS = HERE / "profile_host_regression.py"


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def identities_unchanged(identities):
    for name, identity in identities.items():
        if sha(identity["path"]) != identity["sha256"]:
            raise RuntimeError(name + " changed during measurements")


def body_checks(root):
    rows = []
    for pair in sorted(root.glob("pair-*")):
        for path in sorted((pair / "baseline").glob("trial-*/*.json")):
            a = json.loads(path.read_text())
            if not isinstance(a, dict) or "primary_records" not in a:
                continue
            b = json.loads((pair / "candidate" / path.relative_to(pair / "baseline")).read_text())
            primary = lambda value: sorted((r["marker"], r["request_body_sha256"]) for r in value["primary_records"])
            rows.append({"pair": pair.name, "profile": a["profile"], "workload": a["workload"],
                         "exact_primary_bodies_equal": primary(a) == primary(b),
                         "primary_calls_equal": a["primary_calls"] == b["primary_calls"],
                         "auxiliary_calls_equal": a["auxiliary_calls"] == b["auxiliary_calls"]})
    return rows


def actor_counts(root):
    rows = []
    for path in sorted(root.glob("pair-*/*/own-processes.json")):
        snapshots = json.loads(path.read_text())
        before = [s for s in snapshots if s["role"] == "agent" and s["phase"] == "warm_idle_before"]
        if len(before) != 2:
            raise RuntimeError("expected exactly one base and one full warm-idle Agent snapshot")
        for profile, initial in zip(("base", "full"), before):
            final = next(s for s in snapshots if s["pid"] == initial["pid"] and s["phase"] == "warm_idle_after")
            names = [t["name"]["value"].strip() for t in initial["tasks"] if t["name"]["value"] is not None]
            maps = initial["memory_maps"]
            run = json.loads((path.parent / f"trial-1-{profile}" / "run.json").read_text())
            reaper_idle = []
            for task in initial["tasks"]:
                if "python-kernel" not in (task["name"]["value"] or ""):
                    continue
                other = next((t for t in final["tasks"] if t["tid"] == task["tid"]), None)
                def cpu_ns(t):
                    raw = t["schedstat"]["value"] if t else None
                    return int(raw.split()[0]) if raw else None
                a, b = cpu_ns(task), cpu_ns(other)
                reaper_idle.append({"tid": task["tid"], "cpu_ms": None if a is None or b is None else (b-a)/1e6})
            rows.append({"pair": path.parts[-3], "implementation": path.parts[-2], "profile": profile,
                         "threads": len(initial["tasks"]), "thread_names": names,
                         "reaper_threads": sum("python-kernel" in name for name in names),
                         "fds": len(initial["fds"]), "children": len(initial["children"]),
                         "warm_rss_bytes": None if maps is None else sum(m.get("rss", 0) for m in maps),
                         "private_dirty_bytes": None if maps is None else sum(m.get("private_dirty", 0) for m in maps),
                         "memory_categories": initial["memory_categories"], "reaper_idle": reaper_idle,
                         "idle_seconds": run["idle_seconds"], "idle_cpu_ms": run["idle_cpu_ms"],
                         "startup_online_ms": run["startup_online_ms"],
                         "snapshot_interval_seconds": final["captured_monotonic_s"]-initial["captured_monotonic_s"],
                         "snapshot_errors": initial["errors"]+final["errors"]})
    return rows


def main(args):
    if args.pairs < 4 or args.pairs % 2 or args.iterations < 1:
        raise ValueError("use an even number of pairs >=4 and positive iterations")
    args.out.mkdir(parents=True, exist_ok=False)
    paths = {name: getattr(args, name).resolve() for name in ("baseline", "candidate", "server")}
    paths.update(driver=Path(__file__).resolve(), harness=HARNESS, integrated=HERE / "benchmark_integrated_profile.py", aggregator=HERE / "compare_host_releases.py")
    identities = {name: {"path": str(path), "sha256": sha(path)} for name, path in paths.items()}
    (args.out / "identities.json").write_text(json.dumps(identities, indent=2)+"\n")
    for name in ("driver", "harness", "integrated", "aggregator"):
        shutil.copyfile(paths[name], args.out / paths[name].name)
    started = time.monotonic()
    runs = []
    for delay in args.delays:
        delay_root = args.out / f"delay-{delay:g}"
        for pair in range(args.pairs):
            order = ("baseline", "candidate") if pair % 2 == 0 else ("candidate", "baseline")
            for implementation in order:
                identities_unchanged(identities)
                destination = delay_root / f"pair-{pair+1}" / implementation
                destination.parent.mkdir(parents=True, exist_ok=True)
                command = [sys.executable, str(HARNESS), "--binary", str(paths[implementation]), "--server", str(paths["server"]),
                           "--out", str(destination), "--iterations", str(args.iterations), "--model-delay-ms", str(delay),
                           "--idle-seconds", "1", "--proc-detail", "--profiles", "base", "full"]
                run = {"delay_ms": delay, "pair": pair+1, "implementation": implementation, "command": command, "completed": False}
                runs.append(run)
                (args.out / "runs.json").write_text(json.dumps(runs, indent=2)+"\n")
                with (destination.parent / f"{implementation}.log").open("w") as log:
                    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
                identities_unchanged(identities)
                report = json.loads((destination / "summary.json").read_text())
                if report["binary_sha256"] != identities[implementation]["sha256"] or report["server_binary_sha256"] != identities["server"]["sha256"]:
                    raise RuntimeError("harness identity mismatch")
                run["completed"] = True
                (args.out / "runs.json").write_text(json.dumps(runs, indent=2)+"\n")
                print(json.dumps({"delay_ms": delay, "pair": pair+1, "implementation": implementation, "seconds": time.monotonic()-started}), flush=True)
        summary = {"delay_ms": delay, "summary": aggregate(delay_root), "body_checks": body_checks(delay_root), "actors": actor_counts(delay_root)}
        (delay_root / "comparison.json").write_text(json.dumps(summary, indent=2)+"\n")
    identities_unchanged(identities)
    result = {"identities": identities, "completed": True, "all_hashes_unchanged": True, "seconds": time.monotonic()-started,
              "groups": [json.loads((args.out / f"delay-{d:g}" / "comparison.json").read_text()) for d in args.delays],
              "quantiles": "nearest-rank pooled individual requests within each model-delay/profile/workload/version group",
              "limitations": ["Shared host; coordinated project quiet window is not host isolation, CPU pinning or a confidence interval.",
                              "Synthetic loopback model and mobile observer; not Flutter/WAN/real-model performance.",
                              "Snapshots are before measured batches; process-tree CPU and RSS are not function-level attribution.",
                              "Existing base/full feature envelope only; opt-in profile coordinator is measured separately.",
                              "Nominal 0 and 20 ms model delays remain separate; actual model service times are recorded."]}
    (args.out / "comparison.json").write_text(json.dumps(result, indent=2)+"\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "candidate", "server", "out"):
        parser.add_argument("--"+name, type=Path, required=True)
    parser.add_argument("--pairs", type=int, default=4)
    parser.add_argument("--iterations", type=int, default=60)
    parser.add_argument("--delays", type=float, nargs="+", default=[0, 20])
    main(parser.parse_args())
