# A03 — Product Capability and Interaction Foundation

Status: `DONE — A03-10 ACCEPTED`

## Accepted slices

- A03-00: product structure is frozen. Today is a read projection; Events is
  the Task management center; Calendar manages Schedule; Projects owns the
  long-term Project context; Chat owns Conversation, Message, and Agent
  interaction. Navigation remains Today / Events / Chat / Calendar / Profile.
- A03-01~04: Today, Events, four-quadrant Task behavior, and the shared Task
  Editor are implemented. Today reads TaskRepository and ScheduleRepository;
  `important` and `urgent` preserve `null / false / true`, and quadrant is
  derived rather than stored.
- A03-05: Calendar uses ScheduleRepository for daily view and complete
  Schedule CRUD, including time range, all-day, location, description, and
  reminder validation.
- A03-06: Projects uses the existing Project/Milestone models and Task
  `projectId` relation. Project/Milestone CRUD, tombstones, outbox upload,
  retry preservation, and Next Action selection are covered.
- A03-07: Chat has local-first Conversation/Message behavior, attachment
  metadata flow, send failure and same-message retry, Agent event state, and
  realtime capability/reconnect seams.
- A03-08~09: page-to-domain boundaries are documented; EventRepository remains
  a compatibility facade. Server and Hermes audits found no additional
  product-required API or plugin protocol changes.
- A03-10: final acceptance was re-run independently against the release
  candidate on `orialis-refactor`. Mobile, Rust, contract, and Hermes-
  independent gates reproduce the A03 snapshot; the contract validator
  environment gap is closed. Full evidence and the per-capability READY / NOT
  READY matrix are in
  `A03-10-acceptance-verification.md`.

## A03-10 final acceptance

The integrated A03 scope is accepted. The product surface, domain ownership,
relations, local-first behavior, sync/retry behavior, realtime seams, and
cross-end contracts are complete for the roadmap-defined functional baseline.
The final acceptance intentionally does not add a new wire entity or redesign
the visual system.

The Conversation lifecycle remains an API-refresh path rather than a unified
`sync_events` entity. This is an explicit A03 scope decision: the current
Conversation API and Message realtime contract are consistent across ends, and
introducing Conversation sync events would require a separate protocol decision.

An independent WorkBuddy AI audit using DeepSeek V4.1 Flash confirmed the
page/domain boundaries and the 72-test mobile baseline, and exposed a pytest
module-path issue in the Hermes capability tests. The test seam was corrected
and the full Hermes validation was rerun successfully.

## Verification snapshot

- Mobile: `flutter analyze` exits 0; full `flutter test` passes with 72 tests.
- Rust: `cargo fmt --all -- --check` passes; `cargo test --workspace` passes
  (8 core unit tests, 42 server unit tests, 25 protocol integration tests, and
  doc-tests).
- Contracts: `scripts/validate-contracts.py` validates 14 fixtures against 12
  schemas in an isolated environment using `scripts/requirements-contracts.txt`.
- Hermes: manifest validation, Python compilation, and all 37 plugin tests pass
  with the configured Hermes runtime.
- Repository hygiene: `git diff --check` passes.
- ADB device smoke: Xiaomi Mi 10 / Android 13 (API 33), debug APK built and
  installed successfully; Today, Events, Chat, Calendar, Profile, Project,
  Task Editor, and Schedule Editor opened on-device. Chat also passed the
  pre-release database upgrade after the idempotent migration fix. Offline
  startup produced no unhandled Flutter errors after the realtime readiness
  fix.
- Production cross-end Chat/attachment/reconnect evidence remains unclaimed:
  the device could not resolve the configured production host during this run.

## Deferred and explicit risks

- Conversation CRUD is intentionally not emitted into the unified
  `sync_events` stream; the API-refresh path is the accepted A03 behavior.
- Production cross-end validation remains a release-stage follow-up; the
  physical-device UI smoke gate is complete, but authenticated Chat delivery,
  attachment upload, and realtime reconnect against production were not
  exercised because the configured host was not resolvable on the device.
- Visual redesign remains deferred. UI is functional placeholder quality by
  design; no final design-system migration is part of A03.

## Working state

The A03 release commit `df3cce0` is recorded and pushed to `origin/orialis-refactor`.
No production deployment was performed; the production cross-end follow-up
remains separate from the code release.
