# A02 — Architecture Integration Progress
Status: `CODE COMPLETE WITH EXPLICIT ENVIRONMENT GATES`

This document records the completed, verified A02 slices without claiming a
physical-device test that the current environment cannot provide.

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
- A02.6 Server boundary: configuration/security loading and health/metadata/
  capability handlers are extracted from `main.rs` without changing routes or
  response compatibility.
- A02.8 Reliability closeout: canonical `sync.change_hint`, retryable outbox
  transport failures, response-lost mutation lookup, post-ack base-version
  rebase, and Conversation `version`/`localRevision`/`baseVersion` semantics
  are implemented and regression-tested.
- A02.7 Release gates: contract validation, public Hermes-independent tests,
  conditional full Hermes discovery when its runtime is installed, Rust
  formatting/tests, and visible-but-non-blocking clippy until the existing
  baseline warnings are removed.

## Verification snapshot

- Mobile: `flutter analyze --no-fatal-infos`; 59 tests passed; Drift schema v8
  adds Conversation `localRevision`.
- Rust: `cargo fmt --all -- --check`; workspace tests passed (8 core, 42
  server, 25 protocol integration).
- Contracts: 14 fixtures validated against 12 schemas; boundary fixture tests
  10 passed; public Hermes-independent tests 37 passed under the configured
  Hermes runtime.
- Cross-end smoke: `scripts/chat_bridge_smoke.py` passed against an isolated
  Rust server using the Hermes runtime, covering Mobile WebSocket + HTTP →
  Server → Agent Gateway → Hermes-compatible peer → persisted reply → Mobile
  `message` and `sync.change_hint` frames.
- Git: final closeout commit `90523d4` is pushed to `origin/orialis-refactor`; worktree is clean.

## Explicitly remaining

- A fresh interactive phone send remains an environment gate: the latest
  verification found no ADB device, so the UI send/reply roundtrip is not
  claimed. The production WSS handshake and real Hermes reconnect have passed;
  the synthetic smoke device is not the selected production delivery target.
- A true injected network timeout and attachment-upload failure still require
  a controllable physical-device or gateway fixture; client-side recovery and
  outbox behavior are covered without overstating that proof.
- Clippy is reported in CI with `continue-on-error` because the pre-existing
  server/test modules still emit warnings. It should become a hard gate after
  that baseline is cleaned.
