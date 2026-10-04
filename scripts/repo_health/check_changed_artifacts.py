#!/usr/bin/env python3
"""Reject build products and oversized new blobs in the resolved commit range."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path, PurePosixPath


MAX_NEW_BLOB_BYTES = 1024 * 1024
FORBIDDEN_PARTS = {
    "target", "build", ".dart_tool", ".gradle", "node_modules", "__pycache__",
    ".pytest_cache", ".kotlin", "uploads",
}
FORBIDDEN_EXACT = {
    ".paperclip-runtime", "runtime-data", "runtime", "data", "band/artifacts", "news/evidence",
    "desktop/evidence", "band/.temp_vela", ".news-cache", "mobile/dist",
    "mobile/android/app/release", "mobile/.flutter-plugins-dependencies",
    "mobile/.flutter-plugins", "mobile/android/local.properties", "mobile/.idea",
}
FORBIDDEN_SUFFIXES = {
    ".apk", ".aab", ".rpk", ".o", ".obj", ".a", ".so", ".dylib",
    ".dll", ".exe", ".class",
    ".pyc", ".pyo",
}


def blocked_reason(path: str) -> str | None:
    pure = PurePosixPath(path)
    parts = pure.parts
    if any(part in FORBIDDEN_PARTS for part in parts):
        return "build/cache directory"
    normalized = pure.as_posix()
    if any(normalized == root or normalized.startswith(root + "/") for root in FORBIDDEN_EXACT):
        return "ignored local output directory"
    if pure.name == ".DS_Store" or (pure.match("band/vela/docs/*.zip")):
        return "ignored local output file"
    if pure.suffix.lower() in FORBIDDEN_SUFFIXES:
        return "compiled application/object output"
    return None


def run_git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, check=True, text=True, capture_output=True).stdout.strip()


def changed_paths(root: Path, base: str, head: str, three_dot: bool) -> list[str]:
    spec = f"{base}...{head}" if three_dot else f"{base} {head}"
    args = ["diff", "--diff-filter=ACMRT", "--name-only", "-z", *spec.split()]
    raw = subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout
    return [entry.decode("utf-8", "surrogateescape") for entry in raw.split(b"\0") if entry]


def validate(root: Path, paths: list[str], head: str, allowlist: dict,
             max_bytes: int = MAX_NEW_BLOB_BYTES) -> list[str]:
    problems = []
    for path in paths:
        reason = blocked_reason(path)
        if reason:
            problems.append(f"forbidden changed path ({reason}): {path}")
            continue
        try:
            blob = run_git(root, "rev-parse", f"{head}:{path}")
            size = int(run_git(root, "cat-file", "-s", blob))
        except subprocess.CalledProcessError:
            continue  # A deletion has no candidate blob.
        if size > max_bytes:
            approved = allowlist.get(path)
            if not approved or approved.get("blob_id") != blob or not approved.get("rationale"):
                problems.append(
                    f"oversized new blob ({size} bytes > {max_bytes}): {path} blob {blob}; "
                    "requires exact path, blob_id, and rationale allowlist entry"
                )
    return problems


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--three-dot", action="store_true")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--allowlist", type=Path, default=Path(".github/repo-health/large-blobs.json"))
    parser.add_argument("--max-bytes", type=int)
    args = parser.parse_args()
    try:
        paths = changed_paths(args.root, args.base, args.head, args.three_dot)
        policy = json.loads((args.root / args.allowlist).read_text())
        limit = args.max_bytes if args.max_bytes is not None else policy["max_new_blob_bytes"]
        allowlist = policy["allowlist"]
        problems = validate(args.root, paths, args.head, allowlist, limit)
    except (OSError, subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as exc:
        print(f"changed artifact check failed closed: {exc}", file=sys.stderr)
        return 2
    print(f"Checked {len(paths)} changed paths from {args.base} to {args.head}; size limit {limit} bytes")
    if problems:
        for problem in problems:
            print(f"::error::{problem}")
        return 1
    print("Changed artifact hygiene passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
