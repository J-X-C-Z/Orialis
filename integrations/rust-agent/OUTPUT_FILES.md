# Durable outbound files and artifact events

Implements the Orialis upload/attachment contract from commit `f9a064bf05b18265afd26905e7240777d4ce355c`, including original `adapter.py` `_send_file` and `send_artifact` flows. This module supplies real bytes and persisted upload outcomes. It does not manufacture an artifact from a schema-only model answer.

## Host API

`OutputFiles::open(OutputConfig::new(database_path, spool_directory), attachment_transport).await` opens a private SQLite WAL/FULL journal and mode-0700 snapshot spool. `artifact_roots` defaults to an empty list. The defaults are 512 MiB of spool file contents and 4,096 artifact records, configurable independently of physical RAM. The journal is bound to the transport's opaque origin/device/credential fingerprint. A different identity is refused; a Unix advisory lock also refuses a second service instance for the same journal or snapshot spool, including two different journals pointed at one spool. A persisted random journal epoch separates artifact IDs created by different databases while keeping them stable across restarts.

Each operation has `OutputScope { conversation_id, input_id }`. These values must come from the authenticated inbound turn, not model arguments. They are stored with each artifact and enforced on every lookup, upload, acknowledgement and replay.

- `register_tool_artifact(scope, stable_tool_operation_id, trusted_path, optional_name, mime).await` is **only for a trusted host tool's selected output**. It snapshots the produced file without uploading it. Never call it directly on a model's arbitrary filesystem path. Persist/reuse the tool operation ID; an already registered operation returns its saved handle even if the source has changed or disappeared. Reusing that ID for another source/name/MIME is refused.
- `resolve_media(scope, reference).await` accepts `artifact://<artifact_id>`, a source path registered in this exact turn, or an absolute path under an explicitly configured export root. Everything else is denied. If one source path was registered more than once in the turn, the newest registration is selected; an explicit artifact ID selects an older immutable result without ambiguity.
- `upload(scope, artifact_id).await` returns `Uploaded`, `OutcomeUnknown`, or `Failed`. Successful results replay without HTTP or rereading the original source. An uncertain result never causes an automatic new POST.
- `reconcile_upload(scope, artifact_id).await` is an explicit recovery operation. It sends the same immutable snapshot to the same conversation using the same saved Idempotency-Key. The actual Orialis server returns the original committed metadata when the key already exists. Call this only after the host has decided to reconcile the uncertain operation, not as an unconditional retry loop.
- `outcome(scope, artifact_id).await` reads a persisted result without HTTP.
- `finalize_media(scope, final_body).await` validates all markers and snapshots before any HTTP upload, then uploads/replays each selected artifact. It returns cleaned text, real server `AttachmentMetadata`, and artifact handles only after all results are persisted. On any refusal/unknown/failure it returns an error; retain the original final body and stored outcomes. A partial successful upload remains recoverable and is not uploaded again.

Call finalization **only on the definitive assistant body**. Initial messages, streaming deltas, progress text, retrieved documents and arbitrary tool output must not trigger MEDIA delivery. The gateway owns final reply IDs, `reply_to`, reply-followup handling and final delivery ACKs. A model-generated marker grants no extra filesystem authority.

## Lifecycle integration

`pending_events(scope)` and `pending_events_all()` return batches of at most 256 `OutputEvent { id, scope, artifact_id, payload }` records in original order. The latter supports a device-wide writer while uploads are still running. `notified().await` wakes one writer; always drain the durable records before waiting. Notifications are not the event data.

The payloads follow Orialis event-v1:

1. `artifact.started`: registered name/MIME/size; no invented URI.
2. `artifact.progress`: `snapshot_ready`, with actual snapshot bytes and total bytes.
3. `artifact.progress`: `uploading`; no fabricated percentage or claimed remote progress.
4. `artifact.completed`: only after successful HTTP metadata validation and durable result commit. Includes the actual download URI, attachment ID, snapshot SHA-256 and original input ID.
5. `artifact.failed`: a confirmed local snapshot failure, or an explicitly labelled `UPLOAD_OUTCOME_UNKNOWN` with `outcomeUnknown:true`. Recovery after an interrupted upload also creates this failure event instead of pretending completion.

The parent must negotiate these capabilities and admit each payload to its normal sequenced durable event outbox, supplying the device epoch/session ID, global sequence and stable event ID. Use a stable source key containing the artifact ID and local event ID so a crash between the two stores cannot duplicate the same lifecycle event. Then call `acknowledge_event(&event.scope, event.id)`. Merely sending a WebSocket frame is not sufficient to acknowledge this local queue. Do not assign independent per-artifact wire sequence numbers.

Per-artifact event retention is bounded at 128 events. Reconciliation admission reserves space for the resulting completion/failure and crash recovery. Accepted events remain as history until explicit safe pruning. All result/event writes occur in SQLite transactions. Failed remote-result persistence is returned as unknown even if the server already accepted the bytes.

## Snapshot and filesystem boundary

Files must be regular, non-empty and no larger than the real server's 20 MiB single-file limit. Names are sanitized, MIME is checked by `AttachmentTransport`, and audio/video remain unsupported by the original Gateway contract. Automatic extension inference supports ordinary text/source, JSON/XML, PDF, ZIP and common images; other files use `application/octet-stream`. Known audio/video extensions are rejected. This is transport, not document extraction or media decoding.

Roots are explicit existing absolute directories, pinned by open directory descriptors. Automatic reads traverse `openat` with `O_NOFOLLOW`, reject symbolic links, hard links, traversal, ADS/colon and NUL paths, and refuse common credential/configuration paths such as `.env`, `.ssh`, `.aws` and `.git`. A renamed/replaced root pathname does not change the original authorized directory descriptor. These protections are not an OS sandbox; choose dedicated export directories, not an entire home directory. A privileged same-UID process can still alter its own files or namespaces.

A snapshot is copied in bounded 64 KiB chunks to an exclusive unpredictable mode-0600 temporary file. The source's inode/size/mtime/ctime must stay stable throughout copying. SHA-256, flush/fsync, atomic rename and directory fsync precede the journal commit. The upload transport compares the persisted SHA to the same open file used for HTTP, then checks its streamed hash again before completing the multipart body. File mutation cannot silently turn one artifact operation into another payload. Any interrupted HTTP result is treated conservatively as unknown.

Spool accounting includes crash leftovers, not just journal rows. Unknown partials are neither overwritten nor silently deleted. Quota refusal asks for explicit maintenance. Record limits retain pending/failed/unknown outcomes rather than evicting work needed for recovery. Directory/inode and SQLite overhead are additional to the byte cap.

Unix descriptor protection and advisory locks are required. Windows support is **not implemented** and is rejected explicitly; this module does not claim cross-platform sandboxing.

## Retention and recovery

Before admitting a prepared final reply to its durable outbox, call `bind_final(message_id, scope, &[artifact_id,...])` with exactly the attachments selected for that reply. The binding requires actual uploaded metadata, is immutable and is not a delivery claim. `ack_final(message_id)` then consumes only a successful authoritative final-reply ACK and marks the selected artifacts delivered. It works after restart without a scope in RAM, returns false for unrelated IDs and safely accepts duplicate matching ACKs. Startup reconciliation uses `pending_final_bindings(after_message_id)` to page through unacknowledged IDs in lexicographic order, at most 256 per call; compare them with the final outbox's durable successful receipts before calling `ack_final`. Advance to the last ID even when some entries are not yet delivered. This closes the crash gap between recording a final receipt and marking its artifacts delivered. Failed/ambiguous transport outcomes must not call it. `mark_delivered(scope, artifact_id)` remains available when the host has an equivalent durable mapping. `prune_delivered_before(unix_seconds)` deletes only uploaded, marked-delivered old records whose lifecycle events were all admitted to the parent's durable outbox. It removes their snapshots and local records, and old acknowledged final bindings with no remaining artifact references. Pending, unknown, failed and unacknowledged work is never automatically pruned. Retention pruning intentionally ends this module's replay window; the host must retain final-reply/tombstone history for its own duplicate-message window.

A crash before the upload-start transaction cannot have sent HTTP. A crash after it leaves `uploading`, converted to `OutcomeUnknown` on reopening. A lost response after server commit also remains unknown. Neither case automatically repeats upload or the producing tool. An explicit same-key reconciliation can recover the original metadata. Producing-tool durable execution is a separate host executor responsibility; this module does not rerun a tool.

## MEDIA grammar

Supported: case-insensitive `MEDIA:/absolute/path`, quoted paths containing spaces, `MEDIA:artifact://id`, and balanced Markdown emphasis wrappers. Unicode paths are preserved. Code fences (including longer fences), inline-code examples, blockquotes, indented code, escaped directives and embedded word fragments are ignored. Relative paths, home expansion, Windows drive paths, remote URLs, arbitrary Markdown/HTML images, and unquoted paths containing whitespace are not interpreted as local deliverables. Quote paths with spaces or use the artifact ID. When no deliverable marker is present, final text is returned byte-for-byte unchanged with empty attachment/handle lists. The final body is capped at 256 KiB and at most 16 attachment directives, matching the Gateway attachment-count limit.

## Reproducible verification

From the workspace root:

```
CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test output_files_transport

ORIALIS_TEST_SERVER_BINARY=$PWD/orialis/target/release/orialis-server \
  CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test output_files_transport -- --include-ignored
```

The real-server test starts the actual compiled Orialis server, isolated SQLite/upload storage, a local fixture account and an authenticated conversation in the test's process tree. It uploads an immutable snapshot, downloads and compares exact bytes, checks real server attachment/idempotency rows, removes the original source, reopens the client journal and verifies one original server artifact plus identical replayed metadata. Fake-server tests inject commit-before-response corruption and cancellation, verify no automatic repost, then explicitly reconcile one server artifact using the same key. Additional tests cover quotas, hard/symlinks, pinned roots, tampering, scope/identity isolation, one writer, events and retention. No production credentials, deployment or push are used.

These tests establish module behavior. The mobile → Orialis → Rust agent → final reply/event transport integration requires its own end-to-end tests; parser/schema acceptance alone does not establish that integration.
