# A02 — Repository Boundaries and Cleanup Order

Status: `CODE COMPLETE WITH EXPLICIT ENVIRONMENT GATES`

This document defines the order for repository cleanup after A01. It does not
authorize deleting compatibility code or moving files before the cross-end
contract gate passes.

## Stable ownership boundaries

| Area | Owns | Must not own |
|---|---|---|
| `orialis-core` | Shared Rust domain values and stable serialization rules | HTTP handlers, SQL rows, mobile-local state |
| `orialis-server` | SQL rows, HTTP request/response DTOs, transactions, sync events | Flutter/Hermes implementation details |
| `protocol/contracts` | Machine-readable cross-end entity/request/event contracts and fixtures | Database migration logic |
| `integrations/hermes/orialis` | Hermes wire adapter, protocol validation, plugin tools | Mobile database models or server SQL types |
| `mobile/lib/core/database` | Drift tables and generated database records | HTTP request construction |
| `mobile/lib/core/sync` | Local revision, outbox state, pull/push orchestration | UI rendering and direct widget state |
| `mobile/lib/core/network` | HTTP session and resource transport | Drift writes and UI state |
| `mobile/lib/core/realtime` | WebSocket lifecycle and event hints | Being the only source of persisted messages |
| `mobile/lib/features/*/data` | Repository mapping between local records and feature operations | Cross-feature database schema ownership |
| `mobile/lib/pages` | Presentation and user interaction | Direct protocol or SQL construction |

## Naming compatibility rule

The following mapping is intentional and must remain explicit:

```text
domain/API concept: Schedule
storage/API compatibility type: CalendarEvent
database table: calendar_events
sync entity type: calendar_event
```

No cleanup batch may replace `calendar_event` with `schedule` on the wire or
remove `/api/v1/calendar-events` until a separately approved compatibility
cycle is complete.

## Ordered cleanup batches

### A02.1 — Hygiene and evidence

- Keep generated output out of version control through `.gitignore`.
- Add shared request/event/tombstone fixtures without moving existing models.
- Add reproducible migration and runtime-load smoke commands.
- Record test evidence in the A01 release report.

Status: `IMPLEMENTED` for the repository-local portion. The validator, Hermes
plugin smoke entry point, CI workflow, and A01 evidence update are present;
live runtime reload remains an environment gate.

### A02.2 — Atomic local writes

- Put entity mutation and initial outbox insertion in one Drift transaction.
- Keep `mutationId`, `baseVersion`, `localRevision`, and remote `version` distinct.
- Add failure-injection coverage for the first-write crash window.

Status: `IMPLEMENTED`. Task/Schedule entity writes and initial outbox entries
share one Drift transaction, with failure-window coverage.

### A02.3 — DTO separation

- Keep SQL rows, HTTP DTOs, shared domain values, Drift records, and wire maps
  distinct even when their product names match.
- Rename only with a fixture-backed compatibility test and an explicit owner.

Status: `IMPLEMENTED`. The contract registry, DTO fixtures, repository
facades, and compatibility tests establish the boundary without a risky
cross-layer rename.

### A02.4 — Documentation index

- Treat `protocol/contracts` as the machine-readable source of truth.
- Keep `docs/api-v1.md` as HTTP behavior, `docs/sync.md` as sync behavior,
  and the Agent Gateway README as the agent protocol.
- Convert overlapping documents into links or migration notes before deleting
  any content.

Status: `IMPLEMENTED`. The contract registry, API behavior, sync behavior,
Agent Gateway protocol, and this boundary document are now linked by the A02
progress record; overlapping legacy names remain documented as compatibility
notes.

## Release gate

A01 is closed. A02 code is complete, with real-device UI delivery and
controllable network-failure injection remaining explicit environment gates.
Clippy remains visible but non-blocking until the pre-existing warning
baseline is removed.
