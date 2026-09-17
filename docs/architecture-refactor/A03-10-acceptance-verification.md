# A03-10 — Final Acceptance Verification

Status: `ACCEPTED — VERIFIED WITH EXPLICIT FOLLOW-UPS`

This slice records an independent re-run of the A03 acceptance gates on
2026-09-17, against the A03 release candidate on `orialis-refactor`
(`df3cce0`). It does not introduce new product scope and does not change any
code.

## Gate results

| Gate | Command | Result |
| --- | --- | --- |
| Mobile static analysis | `flutter analyze` | PASS — `No issues found!` |
| Mobile tests | `flutter test` | PASS — 72 passed, 0 failed |
| Rust formatting | `cargo fmt --all -- --check` | PASS |
| Rust tests | `cargo test --workspace` | PASS — 8 core + 42 server + 25 protocol = 75 passed, 0 failed |
| Whitespace hygiene | `git diff --check` | PASS |
| Contract registry | `scripts/validate-contracts.py` | PASS — 14 fixtures validated against 12 schemas |
| Hermes plugin compile | `python -m py_compile integrations/hermes/orialis/*.py` | PASS |
| Hermes plugin tests | `HERMES_PYTHON=<venv>/bin/python HERMES_CLI=<venv>/bin/hermes bash scripts/validate-hermes-plugin.sh` | PASS — 37 passed, 0 failed |
| Hermes capability tests under pytest | `<venv>/bin/python -m pytest integrations/hermes/orialis/tests -q` | PASS — 47 passed, 0 failed |
| Hermes runtime validation | `hermes plugins validate <plugin_dir>` | PASS — manifest and registration checks passed |
| ADB device smoke | Xiaomi Mi 10 / Android 13 (API 33): debug APK install, launch, five-tab navigation, Task/Schedule/Project editor open | PASS |
| ADB database upgrade | Preserve device data, install patched APK, open Chat | PASS — pre-release duplicate-column/index failures cleared |
| ADB offline startup | Clear logcat, launch with production host unresolved | PASS — no unhandled Flutter exception after realtime readiness fix |

The mobile and Rust numbers reproduce the A03-progress snapshot exactly
(72 mobile tests; 8/42/25 Rust tests).

## Capability matrix

### Pages and domain boundaries

| Surface | Boundary | Verdict | Evidence |
| --- | --- | --- | --- |
| Today | `TaskRepository` + `ScheduleRepository` | READY | `today_page.dart` watches both providers; reads `watchTasks()` and `watchForDate()`; owns no table or sync stream |
| Events | `TaskRepository` | READY | `events_page.dart` uses `taskRepositoryProvider` only; no Schedule construction |
| Calendar | `ScheduleRepository` | READY | `calendar_page.dart` uses `scheduleRepositoryProvider`; full Schedule CRUD covered |
| Projects | `ProjectRepository` | READY | `projects_page.dart` uses `projectRepositoryProvider`; Project/Milestone CRUD + tombstone + Next Action |
| Chat | `ChatController` + `ChatRepository` | READY | `chat_page.dart` uses `chatMessagesProvider`, `syncCoordinatorProvider`, `realtimeClientProvider` |
| Profile | `appConfigProvider` | READY (documented exception) | Infrastructure settings only; `architecture.md` explicitly exempts it |

Boundary audit: no page references `AppDatabase` as a type or instance, and no
page imports `package:drift` or `package:dio` except `profile_page.dart`, which
is the documented infrastructure exception. Pages reach data only through
Riverpod providers. The A03-08 boundary claim holds.

### Entities

| Entity | Verdict | Evidence |
| --- | --- | --- |
| Task | READY | `task_quadrant_test`, `local_mutation_queue_test`, `repository_test`; `important`/`urgent` keep `null/false/true`, quadrant is derived |
| Schedule | READY | `schedule_repository_test`; separate from Task — no `completed`/`important`/`urgent`/`due` |
| Project | READY | `project_repository_test`, `project_milestone_sync_test`, `project_milestone_api_test` |
| Milestone | READY | same suites; parent immutable, completion does not create a Schedule |
| Conversation | READY WITH CAVEAT | `chat_repository_test` covers lifecycle and `default` protection; **not emitted into `sync_events`** |
| Message | READY | `chat_repository_test`, `message_pagination_test`, `attachment_bridge_test` |

### Reliability surfaces

| Surface | Verdict | Evidence |
| --- | --- | --- |
| offline | READY | Drift-backed local-first reads/writes; app starts and mutates without a server |
| sync | READY | `sync_state_test`, `sync_coordinator_test`, `project_milestone_sync_test`; snapshot recovery, cursor advancement, multi-page drain |
| outbox | READY | `outbox_store_test` (11 cases), `local_mutation_queue_test`; durable mutations survive restart |
| retry | READY | Chat send-failure retry on the same message; outbox retryable transport failures; server `cancelled_request_can_be_retried_with_the_same_message_id` |
| realtime | READY | `realtime_client_test`, `mobile_realtime_client.dart`; WebSocket carries heartbeat and change hints only |
| reconnect | READY | `event_sequence_is_idempotent_and_survives_reconnect`, `same_device_reconnect_does_not_remove_other_devices`, `server_events_receive_sequences_and_can_be_replayed` |

## Not ready / gated

1. **Production cross-end evidence.** The ADB UI smoke gate passed on a Xiaomi
   Mi 10 / Android 13 (API 33), including the preserved-data database upgrade.
   Production reachability is now verified from the host with
   `GET /api/v1/health` returning 200 and from the selected device with DNS and
   ICMP success. A device-side authenticated test send entered the retry state;
   authenticated delivery, attachment upload, and realtime reconnect therefore
   remain unproven. This is a release-stage follow-up, not an A03 acceptance
   blocker.
2. **Conversation sync stream.** Conversation CRUD remains on the Conversation
   API refresh path by explicit A03 scope decision; Message realtime and the
   existing sync contracts remain unchanged. A future unified Conversation
   sync entity requires a separate cross-end protocol decision.
3. **Visual design system.** Deferred by design; the UI is functional
   placeholder quality and no design-system migration is part of A03.
4. **Integration state.** The A03 release commit `df3cce0` is committed and
   pushed to `origin/orialis-refactor`. Nothing has been deployed to
   production.

## Findings from this pass

- **Contract validator environment gap is closed.** Installing
  `scripts/requirements-contracts.txt` (`jsonschema` 4.26.0) makes
  `scripts/validate-contracts.py` pass: 14 fixtures against 12 schemas. The gap
  recorded in A03-05/A03-06 and A03-progress can now be marked resolved.
- **Hermes pytest import-path issue is fixed.** The capability tests now patch
  the module object imported by the test itself, so both pytest and the
  documented unittest discovery path exercise the same seam without a live
  network call.
- **Forward-looking risk in the validator.** `validate-contracts.py` imports
  `jsonschema.RefResolver`, deprecated since jsonschema 4.18 and scheduled for
  removal. The script still works on 4.26.0 but emits a `DeprecationWarning` on
  every run; it should migrate to the `referencing` API before the pin is
  raised.
- **Local proxy configuration can interfere with live-network test paths.** With
  `HTTP_PROXY` / `HTTPS_PROXY` exported in the shell, `flutter_tester` can fail
  to complete its loopback WebSocket upgrade and Python `urlopen` in the Hermes
  capability tool can tunnel out to a 502. The Hermes test seams now patch the
  imported module objects, so both pytest and unittest discovery stay offline
  and deterministic.
- **Hermes interpreter selection is the highest-risk trap.** The plugin gates
  only reach 37 tests when run with the Hermes runtime interpreter and CLI
  (`HERMES_PYTHON=<hermes-agent>/venv/bin/python`,
  `HERMES_CLI=<...>/bin/hermes`). A stock system Python has no `gateway`
  package, so `test_adapter.py` and `test_roadmap_plugin.py` fail to import and
  the suite silently degrades to 21 tests while still reporting success. Any
  automated gate should assert the expected test count rather than exit status
  alone.
- **Bytecode cache writes can abort the Hermes gate.** `validate-hermes-plugin.sh`
  runs `py_compile` and `unittest` against
  `integrations/hermes/orialis/__pycache__`. In a restricted shell that cannot
  unlink pre-existing `.pyc` files, the script aborts after manifest validation
  even though the manifest checks passed. Setting `PYTHONPYCACHEPREFIX` to a
  writable directory lets the test phase complete.
- **Sandbox interference with the Rust and Flutter build trees.** `cargo test`
  and `flutter test` both need to unlink files under `target/`,
  `.dart_tool/hooks_runner/`, and `build/native_assets/`. Running them from an
  unrestricted shell, or pointing `CARGO_TARGET_DIR` outside the repository,
  avoids the failure.
- **Verification artifacts left in the assistant workspace.** The re-run used
  `/Users/jxcz/WorkBuddy AI/2026-09-17-19-23-03/.cargo-target` (Rust build
  cache) and `.../orialis-mobile-verify` (a copy of `mobile/lib` and
  `mobile/test`). Neither touches the repository and both are safe to delete
  once the verification is archived.

## Verdict

A03-10 is `READY` and accepted for the roadmap-defined functional baseline.
The physical-device UI smoke gate is complete. Production cross-end evidence,
visual redesign, and commit/push/deploy remain explicit release-stage
follow-ups. Conversation sync events are out of scope for A03 and require a
separate protocol decision before implementation.
