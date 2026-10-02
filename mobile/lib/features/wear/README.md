# Phone–wearable read-only synchronization

Updated 2026-10-03, TASK-039 / COORD-031; source: current code, Xiaomi official SDK and Fangcun interconnect verification notes.

Android now uses `XiaomiWearAdapter` with the official 1.4 AAR. Its provenance/hash is in `android/app/libs/README.md`. SDK calls use asynchronous callbacks on a serialized executor. The UI supports service/node discovery, explicit node selection, DEVICE_MANAGER authorization, opening the watch app, Ping/Pong and manual snapshot synchronization. Unknown installation-query results are not misreported as absent; an explicit false blocks sending. Notification permission is not required for data messages.

`WearAccountSnapshotSource` calls existing authenticated `session()` and `syncSnapshot()` APIs with frozen credentials. The server transaction selects Tasks, Schedules, Projects and Milestones for the authenticated account. An identity listener plus final server/token comparisons discard a changed identity, including change-and-restore. Whitelisted fields omit credentials, chat and server user IDs. This is a read-only server projection; it does not mutate the phone DB or run SyncEngine.

If authenticated reading fails, the shared local DB remains available only as an unverified preview. It cannot be sent. The phone's shared DB has not been migrated or declared account-safe. Offline edits that have not reached the server are therefore not part of a verified wearable snapshot.

The projection preserves domain fields and relationships, with at most 64 candidates per domain and a 16 KiB complete snapshot. Round-robin selection and coverage counts disclose truncation. `today` and UTC display offset come from the phone. A successful server read is `dataState: live`, but SyncEngine completion status/time remain unknown. No independent execution-device status is inferred.

Frames use `orialis.wear.v1`; the 2,200-byte conservative transport budget includes the serialized JSON envelope and escaping (Fangcun experience, not a Xiaomi contractual maximum). Snapshot identity, revision and checksum must match. Send callback alone never establishes completion: the wearable writes and reads back its cache before returning `snapshot.ack`. Session/target/identity revocation invalidates pending operations and previews; no replay queue is persisted. Watch data remains an offline read-only copy; no watch business mutation is exposed.

Android and RPK must share package `top.jxcz.orialis` and signing certificate. Debug signing uses the existing local Android debug certificate; local Vela signing material stays ignored and must never be committed. A copied RPK is not proof of installation. Install it through the wearable's supported developer path, keep Mi Fitness available, then verify node, permission, Pong and persistence ACK independently.

Validation: 15 focused Flutter tests (9 transport/protocol and 6 account-source cases), Kotlin/Android debug build, and targeted analysis. `integration_test/wear_native_test.dart` is an explicit real-device acceptance test (`--dart-define=WEAR_REAL_DEVICE=true`); it reads the existing login, never changes phone records, refuses ambiguous multiple nodes, and requires a real persistence ACK. The attempted run on 2026-10-03 could not start because USB phone 83626d06 disappeared. Real device E2E is still pending; builds and simulation do not establish it.
