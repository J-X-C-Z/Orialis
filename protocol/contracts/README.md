# Orialis Contract Registry

This directory is the machine-readable registry for cross-platform contracts.

## Rules

- `domain/` defines public entity shapes shared by Server, Mobile, and Plugin.
- `http/` will define HTTP request, response, error, and compatibility shapes.
- `agent-gateway/` contains the versioned Agent Gateway schemas.
- `fixtures/` contains representative payloads used by cross-platform tests.
- `docs/` explains semantics and migrations; it is not a competing field source.

Run `python scripts/validate-contracts.py` from the repository root to validate
all published fixtures and their cross-fixture identity/tombstone invariants.
The command uses the pinned dependency in `scripts/requirements-contracts.txt`.

The first slice is `Task` and `Schedule` v1. The existing `calendar_event` wire
value remains the v1 sync compatibility value even though the domain name is
`Schedule`.

Tasks may be linked directly to one parent task or one schedule through
`parentTaskId` or `scheduleId`; the two links are mutually exclusive. Parent
tasks must belong to the same user, cannot be the task itself, and cannot
create cycles or nested child tasks. Children retain independent due dates,
priority, and completion state. Completing a parent completes its direct
children; completing all non-empty direct children completes the parent.
Uncompleting a child reopens its parent, while reopening a parent leaves child
completion unchanged. Deleting a task or schedule soft-deletes its direct
children. The UI must confirm the affected scope before deletion. These
lifecycle rules require the service mutation to update versions and emit
outbox/sync events atomically.

`parentTaskId` and `scheduleId` are nullable additions and may be omitted by
legacy clients. Omission on a patch preserves the stored link; explicit `null`
clears it. Schedule `important` defaults to `false` when omitted by legacy
clients.

## Compatibility

Schemas are strict for published fixtures. Additive changes require an explicit
compatibility review. A field that is not implemented end-to-end is not part of
the v1 public schema; it must be recorded as Deferred in the A01 inventory.
