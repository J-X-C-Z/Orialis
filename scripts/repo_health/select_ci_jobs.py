#!/usr/bin/env python3
"""Fail-closed changed-path selector for component CI jobs."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Mapping


JOB_NAMES = (
    "rust",
    "contracts",
    "python",
    "mobile",
    "macos_client",
    "website",
    "vela",
    "lumina_flutter",
    "lumina_web",
    "workflow",
)


def event_range(event_name: str, event: Mapping, event_sha: str | None = None) -> tuple[str, str]:
    if event_name == "pull_request":
        pull = event.get("pull_request")
        if not isinstance(pull, dict):
            raise ValueError("pull_request event is missing pull_request data")
        base = pull.get("base", {}).get("sha") if isinstance(pull.get("base"), dict) else None
        head = pull.get("head", {}).get("sha") if isinstance(pull.get("head"), dict) else None
        if not isinstance(base, str) or not isinstance(head, str) or not base or not head:
            raise ValueError("pull_request event is missing base/head SHA")
        return base, head

    if event_name == "push":
        before = event.get("before")
        after = event.get("after")
        if not before or not after:
            raise ValueError("push event is missing before/after SHA")
        if event_sha and after != event_sha:
            raise ValueError("push after SHA does not match GITHUB_SHA")
        if not isinstance(before, str) or not isinstance(after, str):
            raise ValueError("push before/after SHA must be strings")
        return before, after

    raise ValueError(f"unsupported event type: {event_name}")


def git_changed_paths(root: Path, base: str, head: str) -> list[str]:
    empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    if len(base) != 40 or len(head) != 40:
        raise ValueError("event range contains a malformed SHA")
    if set(head) == {"0"}:
        raise ValueError("head SHA cannot be the all-zero value")
    if set(base) == {"0"}:
        base = empty_tree
    else:
        subprocess.run(["git", "cat-file", "-e", f"{base}^{{commit}}"], cwd=root,
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    subprocess.run(["git", "cat-file", "-e", f"{head}^{{commit}}"], cwd=root,
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    result = subprocess.run(["git", "diff", "--name-only", "-z", base, head], cwd=root,
                            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return [path.decode("utf-8", "surrogateescape") for path in result.stdout.split(b"\0") if path]


def matches(path: str, *roots: str) -> bool:
    return any(path == root or path.startswith(root.rstrip("/") + "/") for root in roots)


def select_jobs(paths: list[str]) -> dict[str, bool]:
    all_paths = set(paths)
    workflow = any(matches(path, ".github/workflows") for path in paths)
    selector_changed = any(path in {
        "scripts/repo_health/select_ci_jobs.py",
        "scripts/repo_health/tests/test_select_ci_jobs.py",
    } for path in paths)
    run_all = workflow or selector_changed

    def changed(*roots: str, exact: tuple[str, ...] = ()) -> bool:
        return run_all or any(matches(path, *roots) or path in exact for path in paths)

    rust_shared = ("Cargo.toml", "Cargo.lock")
    flutter_shared = ("mobile/pubspec.yaml", "mobile/pubspec.lock")
    mobile_drift_gate = ("scripts/repo_health/check_drift_generated.py",)
    return {
        "rust": changed("orialis-core", "orialis-server", "protocol", "packages/contracts",
                        "scripts/roadmap-e2e", "tests/roadmap",
                        exact=(*rust_shared, "scripts/check-migration-checksums.py",
                               "scripts/repo_health/clippy_diagnostics.py",
                               ".github/repo-health/clippy-baseline.json")),
        "contracts": changed("protocol", "packages/contracts", "integrations/hermes/orialis",
                             exact=("scripts/validate-contracts.py", "scripts/requirements-contracts.txt")),
        "python": changed("integrations/news", "integrations/codex_gateway", "integrations/orialis_sdk",
                          "integrations/hermes", "scripts", "tests", "protocol", "packages/contracts",
                          exact=("scripts/requirements-contracts.txt",)),
        "mobile": changed("mobile", "packages/lumina_ui", "packages/lumina_tokens", "protocol",
                          exact=(*flutter_shared, *mobile_drift_gate)),
        "macos_client": changed("mobile", "packages/lumina_ui", "packages/lumina_tokens",
                                "protocol", exact=(*flutter_shared, *mobile_drift_gate)),
        "website": changed("website"),
        "vela": changed("band/vela", "protocol", "packages/contracts"),
        "lumina_flutter": changed("packages/lumina_ui", "packages/lumina_tokens"),
        "lumina_web": changed("packages/lumina_web", "packages/lumina_tokens"),
        "workflow": run_all or any(path in all_paths for path in (".github/workflows/ci.yml",)),
    }


def write_outputs(outputs_path: Path, jobs: Mapping[str, bool]) -> None:
    with outputs_path.open("a", encoding="utf-8") as stream:
        for name in JOB_NAMES:
            stream.write(f"{name}={'true' if jobs[name] else 'false'}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", type=Path, required=True)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--event-sha")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, default=None)
    args = parser.parse_args()
    try:
        event = json.loads(args.event.read_text(encoding="utf-8"))
        if not isinstance(event, dict):
            raise ValueError("event payload must be a JSON object")
        base, head = event_range(args.event_name, event, args.event_sha)
        paths = git_changed_paths(args.root, base, head)
        jobs = select_jobs(paths)
        output = args.output or (Path(os.environ["GITHUB_OUTPUT"]) if "GITHUB_OUTPUT" in os.environ else None)
        if output is None:
            raise ValueError("GITHUB_OUTPUT or --output is required")
        write_outputs(output, jobs)
        summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_path:
            selected = [name for name, enabled in jobs.items() if enabled]
            not_selected = [name for name, enabled in jobs.items() if not enabled]
            with Path(summary_path).open("a", encoding="utf-8") as summary:
                summary.write("### CI component selection\n\n")
                summary.write(f"Changed paths selected: {', '.join(selected) or '(none)'}\n\n")
                summary.write(f"Not triggered by changed paths (not a pass): {', '.join(not_selected) or '(none)'}\n")
    except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError,
            subprocess.CalledProcessError) as exc:
        print(f"CI job selection failed closed: {exc}", file=sys.stderr)
        return 2
    print(f"Selected CI jobs for {args.event_name} {base}..{head}: " +
          ", ".join(name for name, selected in jobs.items() if selected))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
