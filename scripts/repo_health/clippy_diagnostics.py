#!/usr/bin/env python3
"""Capture and compare stable Rust compiler diagnostics for the Clippy gate."""

from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
from pathlib import Path


CLIPPY_COMMAND = [
    "cargo", "clippy", "--workspace", "--all-targets", "--all-features",
    "--message-format=json", "--locked",
]


def capture(output: Path, root: Path) -> int:
    completed = subprocess.run(CLIPPY_COMMAND, cwd=root, text=True, capture_output=True)
    records = []
    for line_number, line in enumerate(completed.stdout.splitlines(), 1):
        try:
            item = json.loads(line)
        except json.JSONDecodeError as exc:
            print(f"invalid Cargo JSON on stdout line {line_number}: {exc}", file=sys.stderr)
            return 2
        if item.get("reason") == "compiler-message":
            message = item["message"]
            message["package_id"] = item.get("package_id")
            message["target"] = item.get("target")
            for span in message.get("spans", []):
                filename = span.get("file_name")
                if filename and Path(filename).is_absolute():
                    try:
                        span["file_name"] = Path(filename).resolve().relative_to(root.resolve()).as_posix()
                    except ValueError:
                        pass
            records.append(message)
    output.write_text("".join(json.dumps(item, ensure_ascii=False, sort_keys=True) + "\n" for item in records))
    if completed.stderr:
        if not completed.stderr.endswith("\n"):
            completed.stderr += "\n"
        sys.stderr.write(completed.stderr)
    print(f"captured {len(records)} compiler messages in {output}")
    if completed.returncode:
        print(f"cargo clippy exited {completed.returncode}", file=sys.stderr)
    return completed.returncode


def normalized(value: str | None) -> str:
    return re.sub(r"\s+", " ", value or "").strip()


def fingerprint(message: dict, repo_root: Path) -> tuple:
    package = str(message.get("package_id") or "").split("#")[-1]
    target = message.get("target") or {}
    primary = next((span for span in message.get("spans", []) if span.get("is_primary")), {})
    filename = primary.get("file_name") or ""
    path = Path(filename)
    if path.is_absolute():
        try:
            filename = path.resolve().relative_to(repo_root.resolve()).as_posix()
        except ValueError:
            filename = path.name
    span_text = " ".join(normalized(part.get("text")) for part in primary.get("text", []))
    return (
        message.get("level"),
        (message.get("code") or {}).get("code"),
        package,
        target.get("name"),
        tuple(target.get("kind") or []),
        normalized(message.get("message")),
        filename,
        normalized(span_text),
        normalized(primary.get("label")),
    )


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        raise ValueError(f"diagnostic file does not exist: {path}")
    result = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid diagnostic JSON at {path}:{number}: {exc}") from exc
    return result


def diagnostic_counts(messages: list[dict], root: Path) -> collections.Counter:
    return collections.Counter(fingerprint(message, root) for message in messages)


def compare(baseline: list[dict], candidate: list[dict], root: Path) -> tuple[int, int, list, list]:
    old = diagnostic_counts(baseline, root)
    new = diagnostic_counts(candidate, root)
    added = list((new - old).items())
    removed = list((old - new).items())
    added_total = sum(count for _, count in added)
    removed_total = sum(count for _, count in removed)
    return added_total, removed_total, added, removed


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="action", required=True)
    cap = subparsers.add_parser("capture")
    cap.add_argument("--output", type=Path, required=True)
    cap.add_argument("--root", type=Path, default=Path.cwd())
    cmp = subparsers.add_parser("compare")
    cmp.add_argument("--baseline", type=Path, required=True)
    cmp.add_argument("--candidate", type=Path, required=True)
    cmp.add_argument("--baseline-sha", required=True)
    cmp.add_argument("--candidate-sha", required=True)
    cmp.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args()
    if args.action == "capture":
        return capture(args.output, args.root)
    try:
        manifest = json.loads(args.baseline.read_text())
        if manifest.get("source_sha") != args.baseline_sha:
            raise ValueError("baseline source SHA does not match requested baseline SHA")
        baseline = manifest["diagnostics"]
        candidate = read_jsonl(args.candidate)
        added, removed, added_entries, removed_entries = compare(baseline, candidate, args.root)
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"Clippy baseline comparison failed closed: {exc}", file=sys.stderr)
        return 2
    print(f"Clippy baseline {args.baseline_sha}; candidate {args.candidate_sha}")
    print(f"Added diagnostics: {added}; removed diagnostics: {removed}")
    for fingerprint_value, count in added_entries:
        print(f"ADDED x{count}: {fingerprint_value}")
    for fingerprint_value, count in removed_entries:
        print(f"REMOVED x{count}: {fingerprint_value}")
    return 1 if added else 0


if __name__ == "__main__":
    raise SystemExit(main())
