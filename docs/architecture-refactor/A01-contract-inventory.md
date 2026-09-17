# A01 Contract Inventory

Status: `DONE`

This inventory compares the current `orialis-refactor` HEAD with the A01
Task/Schedule v1 target. It intentionally excludes the existing uncommitted
mobile changes from the HEAD baseline.

## Findings

| Area | Current HEAD | A01 target | Status | Risk |
|---|---|---|---|---|
| Task priority | Core uses `Option<bool>`; server migration and Drift use non-null `0/false` | Preserve `null / false / true` end-to-end | Drift | High |
| Schedule name | Core/server/mobile still use `CalendarEvent` in places | Domain name `Schedule`; keep storage and v1 wire compatibility | Partial | Medium |
| Schedule fields | Core has more fields than DB/HTTP/mobile | Public v1 keeps only fully supported fields; extras are Deferred | Drift | High |
| Task recurrence | Docs show object; Core uses string; DB has rule/until; mobile omits it | `{rule, until}` or null | Drift | High |
| IDs | Core migration comment says service-generated; mobile docs expect client-created IDs | Client-created UUIDv7 for offline entities | Drift | High |
| Client versioning | Mobile has `version` and `remoteVersion`; no explicit `localRevision` | Separate local revision, remote version, and request base version | Partial | High |
| Outbox | No mobile outbox table | Persisted local mutation queue | Missing | Critical |
| Idempotency | Server records mutation IDs in sync events; mobile dirty patch derives keys | Persist one mutation ID per logical outbox mutation | Partial | Critical |
| Sync wire name | Server v1 uses `calendar_event` | Preserve v1 wire value; domain uses Schedule | Compatible | Medium |
| CI | No repository CI workflow was found | Contract and language checks become PR gates | Missing | Medium |

## Field classification for A01

### Canonical v1

`Task`: `id`, `title`, `notes`, `important`, `urgent`, `completed`,
`completedAt`, `due`, `dueTime`, `reminderMinutes`, `projectId`, `recurrence`,
`createdAt`, `updatedAt`, `version`, `deletedAt`.

`Schedule`: `id`, `title`, `description`, `location`, `startAt`, `endAt`,
`allDay`, `reminderMinutes`, `createdAt`, `updatedAt`, `version`, `deletedAt`.

### Compatibility

- Database table `calendar_events`.
- v1 sync entity type `calendar_event`.
- `/api/v1/calendar-events`.
- Existing Dart storage identifiers until the local migration is complete.

### Deferred

- Schedule `taskId` and `projectId`.
- Schedule `source` and `externalId` as writable public fields.
- Conversation, Message, Attachment, and AgentEvent contracts.
- Server-side outbox.

## Required A01 evidence

1. JSON Schemas validate all published fixtures.
2. Server and mobile migrations preserve existing data while allowing nullable
   priority values.
3. The mobile outbox persists payload and mutation ID across restart.
4. A retry reuses the same mutation ID; a new local revision creates a new
   logical mutation after the previous one has been sent.
5. Task and Schedule payloads are not silently dropped by sync.
6. Existing `calendar_event` clients continue to synchronize during the v1
   migration cycle.

## Verification snapshot

- `cargo fmt --all -- --check` and `cargo test --workspace`: passed across the
  core, server, protocol integration, and doc-test suites.
- `flutter analyze --no-fatal-infos`, `flutter test`, and `flutter build apk
  --debug`: passed; the debug APK was produced successfully.
- Hermes plugin tests in the Hermes runtime: 37 passed; `hermes plugins
  validate integrations/hermes/orialis --json` passed.
- `python scripts/validate-contracts.py`: passed for all four published
  fixtures, including local `$ref` resolution and mutation/tombstone
  cross-fixture invariants.
- `git diff --check`: passed. Generated Flutter/Python/build output is now
  ignored without deleting any existing files.

## Remaining risks

- Migration `0011` intentionally clears legacy recurrence values that do not
  have the v1 `{rule, until}` shape; production rollout requires a backup and
  an affected-row count first.
- Existing acknowledged outbox rows from pre-A01 code cannot reconstruct a
  lost server version; the new write path is transactional and recovery avoids
  resending. A real old-v5 database migration and a live Hermes reload still
  need an environment-backed smoke test.
- Local release deployment verification passed: release binary started with a
  temporary SQLite database, applied migrations through version 11, served
  health, accepted Task/Schedule writes, enforced DELETE `baseVersion`, and
  emitted sync events.
- Production server revalidation completed with a database backup: the
  compatibility-built binary applied migration 11, remained active, returned
  health 200, passed WSS `hello_ack → pong`, and the real Hermes device
  reconnected. The first candidate was rejected and rolled back cleanly when
  the migration checksum preflight exposed the historical 0001-byte mismatch;
  no `_sqlx_migrations` row was edited.
- The current APK was installed on the wired ADB device and mobile unit tests
  remain green. A fresh interactive phone send after the production restart is
  still a manual UI step because the attached device is currently locked; the
  previous real-device end-to-end run remains the accepted baseline.
