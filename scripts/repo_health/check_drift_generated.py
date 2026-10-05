#!/usr/bin/env python3
"""Regenerate tracked mobile Drift outputs and fail on any repository drift."""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path


def tracked_files(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, check=True, stdout=subprocess.PIPE
    )
    return [path.decode("utf-8", "surrogateescape") for path in result.stdout.split(b"\0") if path]


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    files = tracked_files(root)
    generated = sorted(
        path for path in files
        if path.startswith("mobile/") and path.endswith(".g.dart")
    )
    if not generated:
        print(
            "ERROR: no tracked mobile .g.dart outputs found; "
            "refusing an empty Drift check",
            file=sys.stderr,
        )
        return 2

    missing = [path for path in generated if not (root / path).is_file()]
    if missing:
        print("ERROR: tracked generated outputs are missing before generation:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        return 1

    lock_path = "mobile/pubspec.lock"
    migrations = sorted(
        path for path in files
        if "/migrations/" in f"/{path}" and path.endswith(".sql")
    )
    if lock_path not in files or not (root / lock_path).is_file():
        print(f"ERROR: tracked lock file is missing: {lock_path}", file=sys.stderr)
        return 2
    if not migrations:
        print(
            "ERROR: no tracked SQL migrations found; "
            "refusing an incomplete migration check",
            file=sys.stderr,
        )
        return 2
    protected = [lock_path, *migrations]
    before = {path: (root / path).read_bytes() for path in protected}
    before_hashes = {path: hashlib.sha256(data).hexdigest() for path, data in before.items()}

    command = ["dart", "run", "build_runner", "build"]
    print(f"Running in {root / 'mobile'}: {' '.join(command)}", flush=True)
    generated_result = subprocess.run(command, cwd=root / "mobile")
    if generated_result.returncode:
        print(
            "ERROR: Drift generation failed with "
            f"exit {generated_result.returncode}",
            file=sys.stderr,
        )
        return generated_result.returncode

    changed_protected = []
    for path in protected:
        after = (root / path).read_bytes()
        after_hash = hashlib.sha256(after).hexdigest()
        if after != before[path] or after_hash != before_hashes[path]:
            changed_protected.append(path)
    if changed_protected:
        print("ERROR: generation changed protected lock/migration files:", file=sys.stderr)
        for path in changed_protected:
            print(f"  {path}", file=sys.stderr)
        return 1

    after_generated = sorted(
        path for path in tracked_files(root)
        if path.startswith("mobile/") and path.endswith(".g.dart")
    )
    if after_generated != generated:
        print(
            "ERROR: tracked generated-output enumeration changed during generation",
            file=sys.stderr,
        )
        return 1

    failed = False
    for path in generated:
        if not (root / path).is_file():
            print(
                f"ERROR: tracked generated output is missing after generation: {path}",
                file=sys.stderr,
            )
            failed = True
            continue
        print(f"Checking tracked generated output: {path}", flush=True)
        result = subprocess.run(["git", "diff", "--exit-code", "--", path], cwd=root)
        if result.returncode:
            failed = True
    if failed:
        print("ERROR: generated output drift detected", file=sys.stderr)
        return 1

    print(
        f"Drift generation check passed: {len(generated)} tracked output(s), "
        f"{len(migrations)} SQL migration(s); lock and migrations byte/hash stable."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
