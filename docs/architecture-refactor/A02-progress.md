# A02 — Architecture Integration Progress
Status: `IMPLEMENTED WITH RELEASE GATES`

This document records the completed, verified A02 slices without claiming the
remaining broad refactors are finished.

## Completed slices

- A02.1 Sync lifecycle: app-owned realtime lifecycle, single-flight/coalesced
  `SyncCoordinator`, snapshot recovery, transactional cursor advancement, and
  multi-page incremental drain.
- A02.2 Project/Milestone mobile model: Drift schema v7, migration from v6,
  snapshot and incremental upsert/delete handling, tombstone replay protection,
  and conflict-preserving tests.
- A02.3 Boundary registry: Project, Milestone, Conversation, Message,
  Attachment, Pagination, Snapshot, HTTP Error, Mobile Realtime, and Agent
  Gateway schemas with fixtures and automated discovery.
- A02.4 Conversation/Message semantics: server keyset pagination by
  `created_at,id`, opaque cursors, legacy array compatibility, and mobile page
  consumption.
- A02.5 Repository boundary: TaskRepository and ScheduleRepository facades are
  available while EventRepository remains a compatibility facade.
- A02.7 Release gates: contract validation, public Hermes-independent tests,
  conditional full Hermes discovery when its runtime is installed, Rust
  formatting/tests, and visible-but-non-blocking clippy until the existing
  baseline warnings are removed.

## Verification snapshot

- Mobile: `flutter analyze --no-fatal-infos`; 54 tests passed.
- Rust: `cargo fmt --all -- --check`; workspace tests passed (8 core, 42
  server, 25 protocol integration).
- Contracts: 14 fixtures validated against 12 schemas; boundary fixture tests
  10 passed; public Hermes-independent tests 21 passed.
- Git: `orialis-refactor` is clean and pushed through commit `0659828`.

## Explicitly remaining

- A02.6 server `main.rs` modularization and deeper plugin/mobile physical
  module moves remain intentionally deferred; the current changes preserve
  public compatibility boundaries.
- A02.8 still needs a Hermes-runtime-backed full suite and a fresh interactive
  phone send while the device is unlocked. The production WSS handshake and
  real Hermes reconnect have passed; the synthetic smoke device is not the
  selected production delivery target, so its reply roundtrip was not claimed.
- Clippy is reported in CI with `continue-on-error` because the pre-existing
  server/test modules still emit warnings. It should become a hard gate after
  that baseline is cleaned.
