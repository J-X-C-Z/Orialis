# Incoming document text extraction

`document_extract.rs` performs real bounded text extraction, rather than labelling binary metadata as analyzed content. The extraction code is Rust. PDF conversion is an explicitly configured local Poppler subprocess; it is not a Python backend or a remote upload.

## Host integration

Create `DocumentExtractor::new(DocumentConfig { pdf_program: optional_absolute_pdftotext_path, ..Default::default() })` and put it in `ModelInputLimits.document_extractor`. The extractor is cloneable and permits two active jobs. `prepare_model_input` calls it only on authenticated downloaded attachments and places the results in a **user-role**, JSON-encoded `untrusted_document` object, with attachment name, format, source sections, truncation and warnings. Document text is never treated as system messages, tools, or permission to act. Download URLs and credentials are not sent to the model.

Leaving `document_extractor=None` retains the previous explicit unsupported notices. Enabling the extractor without `pdf_program` permits Office formats but reports that PDF extraction is unconfigured. An executable must be selected explicitly with an absolute existing executable path; there is no PATH lookup, shell command interpolation, installer or automatic network request.

The low-level `extract(cached_path, mime, display_name, remaining_text_budget)` API requires a **trusted cached attachment path** supplied by the host. It is not a general model filesystem tool. It traverses Unix directory descriptors with `O_NOFOLLOW` and accepts only single-linked regular files of 1 byte through 20 MiB. File signatures must match PDF or Office ZIP containers. The format/name determines which constrained parser is eligible, not filesystem authority.

The original fixed Orialis Gateway MIME allowlist accepts `application/pdf`, `application/octet-stream` and `application/zip`, but not Office `application/vnd.*` MIME types. This implementation preserves that transport contract: Office attachments arrive through one of the original generic document MIME types with an appropriate name, then their actual container/parts are checked. Expanding the wire MIME contract requires a coordinated protocol change.

## Actual supported content

- **PDF:** Poppler text, split by actual page separators and labelled `page 1`, `page 2`, etc. This is not rendered visual understanding. Image-only/scanned PDFs return an explicit OCR-required failure rather than a successful empty extraction. Malformed/encrypted/resource-limited files fail explicitly. Embedded images, annotation interpretation and OCR are not implemented.
- **DOCX:** Main document paragraphs/table text, headers, footers, footnotes and endnotes, labelled by actual XML part. These labels are not fabricated page numbers. Rendering, embedded objects, image analysis and semantic interpretation of tracked changes are excluded.
- **XLSX:** Actual workbook relationship mapping, worksheet names and cell references; shared strings, inline strings, numbers/booleans and existing formula caches. Formulas are never executed. A formula without a cached value is explicitly labelled missing, not computed or silently discarded. Date/style rendering, charts, macros, recalculation and external data links are not interpreted.
- **PPTX:** Text in actual presentation slide order, resolved from presentation relationships and labelled by slide number/source. Charts, image content, speaker notes, animations and visual layout are not analyzed.
- **ODT:** Text paragraphs/headings, tabs/line breaks and bounded repeated spaces from `content.xml`. Visual layout, images and embedded objects are not analyzed.

Old binary DOC/XLS/PPT, RTF, macro-enabled extensions, ODS/ODP, arbitrary archives and opaque binaries are explicitly unsupported. UTF-8 XML is required; unsupported XML encodings fail clearly. ZIP64, multi-disk and encrypted containers are unsupported. These limitations are capability gaps, not successful extraction.

## Resource and process boundaries

Defaults are configurable and validated:

- Five-second active-work deadline, at most 30 seconds if explicitly configured.
- 100,000 output bytes including section labels, additionally limited by the remaining shared attachment text budget; at most 256 KiB configured. UTF-8 boundaries are respected and partial output has an explicit truncation warning.
- 4,096 ZIP entries, 4 MiB per XML part, 32 MiB total XML decompression, 64 XML levels and 2,048 output sections.
- Central-directory metadata is checked before ZIP indexing: no multi-disk/ZIP64, entry-count cap, at most 8 MiB of directory bytes and valid source offsets. Each entry name is checked for traversal, ADS/NUL/backslash paths, duplicates, encryption and symlinks. The parser never extracts archive members onto disk.
- Selected XML is streamed in bounded chunks and CRC/actual-size checked. Declared and actual decompression bounds both apply; irrelevant embedded images/objects are not decompressed. DTD declarations, external/custom entity references and XML processing instructions are rejected. Standard/numeric XML character references are decoded without an external resolver. Relationships are package-relative and never fetched from a network.

On Linux, PDF input is an inherited already-open descriptor, addressed through `/proc/self/fd`; the executable receives fixed arguments and emits UTF-8 to a bounded pipe. The subprocess has a separate process group, clean environment, null stdin/stderr, 4 CPU seconds (hard limit 5), 512 MiB address-space cap, zero regular-file output/core-dump limit, bounded descriptors and no-new-privileges. Output overflow stops the process and produces an explicitly truncated result. Timeout/cancellation kills its process group and reaps the direct child. Diagnostics never expose raw document text, paths or stderr.

These limits are **not an OS sandbox**. The operator must use a maintained trusted Poppler installation. Same-UID hostile code, a compromised parser executable, OCR and comprehensive document visual understanding are outside this module's guarantees. Protected PDF subprocess extraction currently requires Linux; Windows support is not claimed.

## Verification

```
CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test document_extract --test attachments_transport
```

Tests use synthetic local files only. Fixtures under `tests/fixtures/documents` were generated by python-docx, openpyxl, python-pptx and reportlab to exercise real document packages, not just schema-shaped data. No Python is used by the runtime parser. Tests also construct targeted minimal and malformed documents, compressed bombs, external entities, traversal, nesting/entry/output limits, missing capabilities and empty PDF content. Actual `/usr/bin/pdftotext` extracts real multi-page PDF text. Controlled local helper processes verify timeout/group cleanup and bounded output. Authenticated attachment download then parsing into the actual model-input JSON is covered separately from parser-only tests.

No real user documents, external accounts, production credentials, deployment or push are involved. Mobile/WS integration and provider behavior are validated separately by the host gateway tests.

Primary dependency references: [zip 9.5.1](https://docs.rs/crate/zip/9.5.1) with only the Rust deflate backend enabled, and [quick-xml 0.42.0](https://docs.rs/crate/quick-xml/0.42.0) without encoding/network/serde expansion features.

## Owner-scoped derived text cache

The measured history-hydration path can now reuse successful `ExtractedDocument`
values in a process-local cache. It does **not** cache complete model messages,
roles, source URLs, user questions, inline images or output delivery state.
`OrialisMediaResolver` still performs the original attachment fetch/reference
validation and keeps the raw-file lease. Current user text, filenames, MIME,
untrusted-data wrappers and notices are rebuilt on every hydration.

The host binds an authenticated owner using
`AttachmentTransport::with_verified_owner_scope(owner.scope())?`, where `owner`
is the result of the authenticated `OwnerVerifier`, not a model field or a
claimed user ID. Without that binding, preparation uses the original uncached
path. Owner binding does not itself authenticate a string: the host must continue
its server-account verification and owner-bound store enforcement. The transport
credential fingerprint is included separately and is **not** mislabelled as a
verified owner.

`DocumentExtractor::extract_scoped(path, mime, name, remaining_bytes, scope)` is
an additive host API. `DocumentCacheScope::new(verified_owner_scope,
transport_namespace, conversation_id)` hashes all three trusted components.
The original public `extract(...)` API remains uncached, so standalone parser
and profiling calls retain their meaning.

Defaults are 16 MiB accounted derived data, 256 records and 15 minutes from
creation. `extractor.with_cache_config(DocumentCacheConfig { ... })?` replaces
that handle's cache with an empty cache under explicit limits; existing clones
retain the previous cache. Zero maximum bytes or entries disables storage.
Maximum accepted limits are 256 MiB, 4096 entries and 24 hours. Expired entries
are ineligible and are removed lazily on the next cache access; there is no
background timer or persistent derived-text database. Dropping all handles drops
the cache. `cache_stats()` exposes aggregate counts/bytes only, not contents,
owner identities, paths or keys. Debug formatting never prints cached text.

Every key includes:

- Verified owner, transport credential namespace and original conversation.
- Actual SHA-256 of the safely opened input bytes, not path/mtime/size alone.
- Parser kind, current MIME/name, complete immutable `DocumentConfig`, exact
  remaining text budget, and implementation/schema version.
- For PDF, actual executable bytes hash and current descriptor version of the
  explicitly configured Poppler binary. The binary is rehashed on hits too;
  these hit costs are not reported as zero. Deployment/runtime dependency
  updates should restart the process, which discards all derived entries.

Every lookup still uses anchored `O_NOFOLLOW` opens, rejects nonregular and
multi-linked inputs, requires current-user 0600 files in a current-user 0700
parent, reads the full input to compute SHA-256, and checks descriptor versions
and current pathname identity before returning cached text. A miss parses the
**same opened file**, then rechecks actual bytes, descriptor/path identity and
PDF executable identity before insertion. Ordinary in-place edits, same-size
replacement, renames, permission changes and links do not reuse stale text.
The boundary does not purport to defeat a malicious process with the same UID
that can rewrite bytes and forge metadata at arbitrary instruction boundaries.

Only successful results are cached. Warnings, page/sheet sources and truncation
are retained exactly. Errors, empty/OCR-only output, malformed containers and
failed parses do not become successes. Per-key single-flight avoids duplicate
concurrent PDF processes; reservation guards clear pending state on errors,
timeouts and cancellation, and blocked workers check their own cancellation and
deadline. The existing two-parser semaphore bounds workers, including cancelled
blocking work that is still stopping. Entry/byte limits and LRU eviction remain
in force; an individual oversized result is returned but not stored. Byte
accounting includes serialized text/warnings plus per-entry/section allocation
allowances, and does not claim to be total process RSS.

`tests/document_cache.rs` has seven passing cases covering same-size/in-place/
rename changes, owner/credential/conversation/budget/config separation, actual
private-file checks on hits, LRU/TTL/disabled/oversized storage, eight concurrent
PDF calls with one producing process, changed executable identity, mutation
during extraction, cancellation, error non-caching, and the actual
`OrialisMediaResolver -> fetch -> prepare_model_input -> extract_scoped` path.
The integration test proves an unbound transport does not cache, bound history
uses the cache without redownloading, and current question/name wrappers are
rebuilt. All inputs, HTTP servers and helper processes are synthetic/local.

```
CARGO_HOME=$PWD/.toolchain/cargo RUSTUP_HOME=$PWD/.toolchain/rustup \
  .toolchain/cargo/bin/cargo test --manifest-path hermes-rust-core/Cargo.toml \
  --test document_cache --test document_extract --test attachments_transport
```

The raw attachment quota/retention scanner, PDF pipe polling strategy and model
history size are unchanged. A cache saves repeated parsing, not provider token
usage or model prefill. Performance claims require the separate frozen-binary
before/after run on identical fixture bytes, not an estimate from hash timings.
