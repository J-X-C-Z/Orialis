"""Minimal schema/fixture checks for the A02.3 boundary contract slice."""

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator, FormatChecker, RefResolver


ROOT = Path(__file__).resolve().parents[4]
CONTRACTS = ROOT / "protocol" / "contracts"
FIXTURES = Path(__file__).parent / "fixtures"


CASES = {
    "project-v1.json": "domain/project.schema.json",
    "milestone-v1.json": "domain/milestone.schema.json",
    "conversation-v1.json": "domain/conversation.schema.json",
    "attachment-v1.json": "domain/attachment.schema.json",
    "message-v1.json": "domain/message.schema.json",
    "pagination-v1.json": "domain/pagination.schema.json",
    "http-error-v1.json": "http/error.schema.json",
    "snapshot-v1.json": "domain/snapshot.schema.json",
    "mobile-realtime-v1.json": "realtime/mobile.schema.json",
    "agent-gateway-v1.json": "agent-gateway/schema-v1.schema.json",
}


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


@pytest.mark.parametrize("fixture_name,schema_name", CASES.items())
def test_boundary_fixture_matches_schema(fixture_name, schema_name):
    schema_path = CONTRACTS / schema_name
    schema = read_json(schema_path)
    schema.pop("$id", None)
    validator = Draft202012Validator(
        schema,
        resolver=RefResolver(schema_path.as_uri(), schema),
        format_checker=FormatChecker(),
    )
    errors = list(validator.iter_errors(read_json(FIXTURES / fixture_name)))
    assert not errors, "\\n".join(error.message for error in errors)
