# Orialis attachment transport

Implemented against Orialis commit `f9a064bf05b18265afd26905e7240777d4ce355c`, especially `orialis-server/src/attachments.rs` and `integrations/hermes/orialis/{adapter,protocol,attachment_cache}.py`.

## Integration API

- Construct `AttachmentConfig::new(server_url, device_id, token, cache_dir)`, then `AttachmentTransport::new(config)`. The server URL can be the configured HTTP or WebSocket URL. The dedicated cache directory is created privately; an existing insecure directory is refused without changing its permissions. Token and device identity are included in the cache namespace fingerprint.
- Parse attachment metadata with `serde_json::from_value::<Vec<AttachmentMetadata>>`. HTTP camelCase fields are accepted and Gateway snake_case fields are serialized. Unknown fields and duplicate aliases are rejected.
- `fetch_message(conversation_id, message_id, &metadata).await` returns a complete vector of `CachedAttachment` or an error. **Never silently continue a turn without an attachment when fetching returns an error.** The caller should return the correlated `ATTACHMENT_UNAVAILABLE` protocol error and preserve retry semantics.
- Keep the returned `CachedAttachment` values alive while working on the turn. Clones share a pin, so pruning cannot delete files under a background model/tool operation. Files survive process restarts and reconnects. Re-fetch reconstructs the same identity-scoped cache path.
- `prepare_model_input(text, &files, &limits).await` returns a user-role `.message` and explicit `.notices`. Pass this message to the provider instead of converting only the original text to a user message. `ModelInputLimits::supports_images` must be set from the actual selected chat model's capability, not the presence of a separate screenshot-analysis model.
- `upload_file(conversation_id, &trusted_path, optional_name, mime, stable_operation_key).await` performs an authenticated, streaming single-file multipart upload. The local path must come from an authorized host operation, not an unrestricted model-supplied path. The operation key must be durably reused across uncertain-result retries; do not retry with a new key. The response metadata must be journaled before replying if crash-safe outbound replay is required. The sibling `OutputFiles` service now provides that lifecycle; see `OUTPUT_FILES.md`. `upload_verified_file` additionally binds the upload to a previously journaled snapshot SHA-256, checked on the same file descriptor used for the HTTP body.
- `attachment_reply(&original_inbound_frame, text, &metadata)` creates the Gateway reply, retaining exact conversation and message correlation and matching the original Python deterministic final-message identity. It does not send or persist that frame. The gateway's normal durable outbox must do so.

## Wire contracts and security

Downloads use authenticated `GET /api/v1/attachments/{id}/download`. Uploads use authenticated `POST /api/v1/conversations/{conversation_id}/attachments` with multipart field `file`. Both carry `Authorization: Bearer ...` and `X-Orialis-Device-Id` only to the configured Orialis origin. Uploads send `Idempotency-Key` and consume `{"items":[...]}` metadata. One HTTP upload produces exactly one metadata item. HTTP error response bodies and credential-bearing URLs are not propagated in errors.

The download origin, scheme, effective port, lack of userinfo/fragment, exact route, and exact attachment ID are validated before any HTTP request. Redirects and environment proxy discovery are disabled. Only the legacy single `token` URL query is accepted. URLs are never inserted in provider prompts; provider image input is a locally produced data URL. Arbitrary same-origin APIs cannot be requested as an attachment. Configuring the server origin is an operator trust decision, including explicitly configured local HTTP services.

Limits follow the two distinct source contracts: each file is at most 20 MiB and incoming Gateway messages permit up to 16 files, hence 320 MiB. The real server's 48 MiB aggregate is a **multipart HTTP request** limit, not a Gateway-message limit. This client uploads one file per request. Missing metadata size is permitted and accounted using actual streamed bytes. MIME mismatches, empty/truncated files, encoded response bodies, over-limit chunked streams, invalid IDs, and non-metadata fields fail explicitly.

Downloads are streamed into exclusive mode-0600 temporary files in owned mode-0700 directories. Cache files use hashes rather than untrusted display names. File and parent checks reject symlinks, hard links, unsafe permissions, and untrusted writable ancestors. Success flushes/syncs the file, atomically renames it, and syncs the directory. Cancellation/error drops unlink the partial file. Existing unrelated paths are not chmod'ed. This protects against other OS users; malicious code running as the same UID is outside the isolation boundary.

The default disk cache is capped at 512 MiB of file contents, 4,096 message directories, and 30-day retention. Old unpinned entries are reclaimed on use, with pins respected. Quota refusal is explicit when all reclaimable entries are pinned. The budgets apply per server/device/credential namespace. Old credential namespaces are not automatically inspected or removed. Directory/inode filesystem overhead is additional to the byte budget. Transport operations are serialized per `AttachmentTransport` to preserve cache accounting and bounded stream memory. Avoid constructing multiple transport instances pointing to the same namespace in one process.

## Actual content support and remaining gaps

UTF-8 text, JSON, XML, and source text are added as clearly marked untrusted user content, within the configured total text budget (default 100,000 bytes). Binary/non-UTF-8 content and control-character payloads are not passed as text. Contents are not treated as system instructions, executable tool calls, or action authorization.

PNG, JPEG, GIF, and WebP bytes can be embedded for a configured image-capable model. Format signatures are checked without invoking a local image decoder; these checks are not a complete decoder/validity check. Default image limits are 4 MiB per image and 8 MiB combined. Exceeding model-input limits yields an explicit notice, not a fictitious summary. A deployment may set larger supported provider limits.

By default, PDF, archives, office formats, opaque binaries, unsupported image formats, and non-UTF-8 text are **not extracted or analyzed by this transport module**. `ModelInputLimits.document_extractor` can now explicitly enable the sibling `document_extract.rs`: real Poppler PDF text (explicit executable only) and bounded Rust DOCX/XLSX/PPTX/ODT text extraction. See `DOCUMENT_EXTRACTION.md` for supported content and the remaining OCR/visual/legacy/encoding gaps. Transport or schema support alone never establishes document understanding. Audio/video remain excluded by the original Gateway contract. This transport module does not implement provider tool authorization or an outbound gateway. The sibling `output_files.rs` implements constrained final-only MEDIA parsing, snapshot registration, artifact lifecycle events and durable upload results; see `OUTPUT_FILES.md`. Gateway/host integration still requires its own end-to-end tests.

## Verification

From the workspace, with the available local Rust toolchain:

```
CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test attachments_transport

ORIALIS_TEST_SERVER_BINARY=$PWD/orialis/target/release/orialis-server \
  CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test attachments_transport -- --include-ignored
```

The ignored real-server test launches the actual Orialis binary as a child of the test process, creates an isolated temporary database and local test account, disables development device authentication, tests upload idempotency, unauthorized download denial, agent-owner authenticated download, and exact text ingestion. All localhost cooperating processes run in one process tree and are terminated on exit. Fake-server tests additionally verify auth headers, zero-request SSRF refusals, redirect refusal, MIME/size/partial cleanup, private cache/symlink defenses, image input, honest unsupported-format notices, streaming upload shape, Python-compatible reply identity, 16 attachments, 60 MiB inbound messages, cancellation, credential isolation, and live-pin retention.

No production credentials, remote service calls, deployment, or push are involved.

Document extraction may use the bounded owner-scoped derived cache described in
`DOCUMENT_EXTRACTION.md`. The host must explicitly bind the authenticated owner
via `with_verified_owner_scope`; an unbound transport preserves uncached parsing.
The credential namespace and source conversation remain part of the derived key.
This does not skip raw reference validation, raw-file leases, actual SHA-256 reads
or private-file checks, and does not change download/upload or quota semantics.
