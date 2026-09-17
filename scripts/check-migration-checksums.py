#!/usr/bin/env python3
"""Compare SQLx migration bytes before a binary is promoted."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path


def checksum(path: Path) -> str:
    digest = hashlib.sha384()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def migration_version(name: str) -> int:
    """Return the numeric SQLx migration version from a filename."""
    match = re.match(r"(\d+)(?:_|\.)", name)
    if match is None:
        raise ValueError(f"invalid migration filename: {name}")
    return int(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--reference-dir",
        type=Path,
        required=True,
        help="migration directory from the currently deployed environment",
    )
    parser.add_argument(
        "--current-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "orialis-server" / "migrations",
    )
    args = parser.parse_args()

    current = {path.name: path for path in args.current_dir.glob("*.sql")}
    reference = {path.name: path for path in args.reference_dir.glob("*.sql")}
    reference_versions = [migration_version(name) for name in reference]
    latest_reference_version = max(reference_versions, default=-1)

    # Migrations newer than the deployed reference are valid additions. Every
    # migration at or below the deployed version is historical and must still
    # exist in both trees, with identical bytes.
    differences: list[str] = []
    for name in sorted(set(current) | set(reference)):
        if name not in current:
            differences.append(f"missing historical migration from current tree: {name}")
        elif name not in reference:
            if migration_version(name) <= latest_reference_version:
                differences.append(f"missing historical migration from reference deployment: {name}")
        else:
            current_hash = checksum(current[name])
            reference_hash = checksum(reference[name])
            if current_hash != reference_hash:
                differences.append(
                    f"checksum mismatch: {name} current={current_hash} reference={reference_hash}"
                )

    if differences:
        print("migration checksum preflight FAILED", file=sys.stderr)
        print("\n".join(f"- {item}" for item in differences), file=sys.stderr)
        print("Do not edit _sqlx_migrations; stop and build a compatibility plan.", file=sys.stderr)
        return 1

    print(f"migration checksum preflight passed ({len(current)} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
