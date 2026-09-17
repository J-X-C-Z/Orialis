#!/usr/bin/env python3
"""Validate the machine-readable Orialis contract registry and its fixtures."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker, RefResolver
except ImportError as exc:  # pragma: no cover - exercised by the CLI error path
    raise SystemExit(
        "jsonschema is required; install scripts/requirements-contracts.txt first"
    ) from exc


ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "protocol" / "contracts"
SCHEMAS = CONTRACTS / "domain"
FIXTURES = CONTRACTS / "fixtures"

FIXTURE_SCHEMAS = {
    "task-unclassified.json": "task.schema.json",
    "schedule-v1.json": "schedule.schema.json",
    "mutation-request-v1.json": "mutation-request.schema.json",
    "sync-event-tombstone-v1.json": "sync-event.schema.json",
}


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"{path.relative_to(ROOT)}: invalid JSON: {exc}") from exc


def validate_fixture(fixture: Path, schema_path: Path) -> None:
    schema = load_json(schema_path)
    # The registry uses stable example HTTPS IDs for documentation.  Local
    # validation must resolve relative references from the checked-out file,
    # never by making a network request to that example domain.
    schema.pop("$id", None)
    resolver = RefResolver(schema_path.as_uri(), schema)
    validator = Draft202012Validator(
        schema,
        resolver=resolver,
        format_checker=FormatChecker(),
    )
    errors = sorted(validator.iter_errors(load_json(fixture)), key=lambda error: list(error.path))
    if errors:
        details = "\n".join(
            f"  - {'.'.join(map(str, error.path)) or '<root>'}: {error.message}"
            for error in errors
        )
        raise SystemExit(f"{fixture.relative_to(ROOT)} failed {schema_path.name}:\n{details}")


def validate_semantics() -> None:
    mutation = load_json(FIXTURES / "mutation-request-v1.json")
    event = load_json(FIXTURES / "sync-event-tombstone-v1.json")
    if mutation["mutationId"] != event["mutationId"]:
        raise SystemExit("mutation and sync fixtures must share mutationId")
    if mutation["entityId"] != event["entityId"] or mutation["entityVersion"] != event["entityVersion"]:
        raise SystemExit("mutation and sync fixtures must preserve entity identity/version")
    if mutation["tombstone"] is not event["tombstone"]:
        raise SystemExit("mutation and sync fixtures must preserve tombstone semantics")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: detected root)")
    args = parser.parse_args()
    if args.root.resolve() != ROOT:
        raise SystemExit("--root is reserved for future multi-repository use")

    for fixture_name, schema_name in FIXTURE_SCHEMAS.items():
        validate_fixture(FIXTURES / fixture_name, SCHEMAS / schema_name)
    validate_semantics()
    print(f"validated {len(FIXTURE_SCHEMAS)} contract fixtures against {len(list(SCHEMAS.glob('*.schema.json')))} schemas")
    return 0


if __name__ == "__main__":
    sys.exit(main())
