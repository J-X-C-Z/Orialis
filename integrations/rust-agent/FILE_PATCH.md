# Native bounded file patch planning

## Scope and integration

`src/file_patch.rs` and its `fuzzy`, `sequence`, and `v4a` submodules contain a native, filesystem-free planner. The existing LocalTools `patch` replace operation now uses the planner. Its confined descriptor-based file access, complete-read requirement, inode/device/content-hash snapshot, approval action binding, approval-time stale check, atomic single-file write, post-write verification, and generated-artifact registration remain in place.

Model-visible results include the chosen strategy, match count, and correction/boundary notes. Approximate-boundary notes also appear in the approval preview. Unknown fields are still rejected. The patch schema now includes confined V4A runtime application and receipt lookup; see [V4A transactions](docs/V4A_TRANSACTIONS.md).

The planner remains pure and filesystem-free. **V4A now also has a Linux runtime** in `src/local_tools/v4a.rs`: Add, Update, Delete and Move use bounded FD-confined staging, one combined exact approval, a private durable journal and conservative restart recovery. Per-file renames are atomic; cross-file visibility is not. No shell, arbitrary filesystem paths, automatic linting, or parent creation is introduced. [Runtime contract, concurrency limits and tests](docs/V4A_TRANSACTIONS.md).

## Source contract

Reference source: Hermes commit `36b98bcced7f3c22d08dd1119240e726b3928e3d`:

- `tools/fuzzy_match.py`
- `tools/escape_drift_autocorrect.py`
- `tools/patch_parser.py`
- `tools/file_operations_common.py`

The reference generator imports these actual source files. It stubs only app initialization, observability and an in-memory POSIX file backend. Source hashes and interpreter version are saved with the fixture. It is not a second hand-written implementation used as the oracle.

Implemented matching strategies, in upstream order: exact, line-trimmed, whitespace-normalized, indentation-flexible, escape-normalized, trimmed-boundary, Unicode-normalized, block-anchor, context-aware. The two similarity strategies use character-based Python SequenceMatcher semantics, including default autojunk filtering, earliest-position ties, and adjacent matching-block merging. Line-trimmed matching shadows indentation-flexible and trimmed-boundary in ordinary orchestration; direct span fixtures exercise them separately.

Supporting behavior includes conservative quote/backslash correction, ambiguous escaping rejection, tab/CR unescaping, line-number gutter recovery, region-specific reindentation, Unicode typography preservation, exact non-overlapping replace-all, ambiguous-match rejection, and rejection of multiple approximate replace-all matches. Error text and correction-note wording are concise native equivalents, not byte-identical upstream diagnostics.

## Public API

- `plan_replace(content, old, new, replace_all, &PatchLimits)` returns `ReplacementPlan { content, match_count, strategy, notes, work_used }` or a typed `PatchError`.
- `parse_v4a(patch, &PatchLimits)` returns ordered typed operations with canonical root-relative lexical paths.
- `plan_v4a(patch, &BTreeMap<String, Option<String>>, &PatchLimits)` returns `PatchPlan { changes, operations, notes, work_used }`. Each `FileChange` has `path`, `before`, and `after`; `None` means explicit absence/deletion.

Missing snapshot keys are errors. A read error is not proof of absence and must never be supplied as `None`. Callers must enumerate all source/destination paths, obtain snapshots through their confined backend, authorize the entire final change, and revalidate every snapshot immediately before committing. A lexical path or a plan is not authorization and does not prove symlink safety. No planner performs I/O.

## Bounds and deliberate divergences

Default limits: 1 MiB per file/patch string, 8 MiB combined referenced file contents, fewer than 100,000 lines per text input, 128 operations, 1,024 hunks, and 32 Mi work units. LocalTools uses its configured file-byte limit (maximum 16 MiB) while retaining the deterministic work bound. Consequently, sufficiently large or expensive edits may require smaller exact patches even when the configured file-byte limit would allow the contents.

Work is charged for scans, line-window comparisons, and SequenceMatcher candidate comparisons. Matching, hint lookup, and shaping have bounded output; indentation amplification is checked before allocating a giant result. A depleted budget returns an error, never a partial edit. This is a deterministic work guard, not a promised CPU deadline.

Deliberate stricter behavior:

- Absolute paths, parent traversal, backslash paths, drive paths, trailing directory spellings, and control characters are rejected. The fixture contains three cases that succeed upstream using absolute aliases; this implementation explicitly checks that they fail closed.
- Overlapping normalized match spans fail closed rather than reproducing upstream's overlapping-splice corruption.
- Incomplete/nested/multiple envelopes and unknown operation headers fail closed rather than being ignored.
- Limits and binary/NUL text are rejected. Existing native text I/O also rejects invalid UTF-8 rather than upstream surrogateescape round-tripping.
- V4A planning follows upstream validation's conservative addition-only behavior: a later hunk cannot rely on text introduced only by an addition-only hunk during validation. Its apply-phase context-hint retry window is not implemented; a resulting mismatch fails closed.

Not included in this increment: upstream file-operation wrapper BOM restoration, whole-file line-ending normalization, already-applied success-shaped replace no-ops, nearest-line diagnostics, unified diff output, and lint/LSP hooks. Core fuzzy outputs preserve upstream matcher behavior, which is distinct from the full upstream file-write wrapper.

## Verification

`python3 scripts/file_patch_reference.py --check` verifies 949 deterministic source-derived cases:

- 413 fuzzy replacements, including 200 generated Unicode edits.
- 9 direct strategy span cases.
- 427 SequenceMatcher block cases, including Unicode, autojunk thresholds, repeated text and tie order.
- 100 V4A parse/validation/application cases on a memory backend.

`cargo test --offline --locked --lib file_patch::tests` exercises pure contracts, malformed paths/envelopes, explicit absence, no partial plans, aliases/moves, overlapping windows, output/reindent/work limits, and the sequence/span oracle.

`cargo test --offline --locked --test file_patch_contract --test local_file_patch --test local_tools` compares fuzzy outputs/counts/strategies and V4A final file states, then exercises the real native tool's complete-read/stale guards, approximate approval notes, denied/once approvals, symlink/hardlink confinement and generated output artifacts. The oracle's backend does not itself validate OS races or permissions; those belong to runtime tests.

## Performance evidence

See `results/file-patch-parity/benchmark-matched-metric.jsonl`, the adjacent validation logs and reference summary. Build the isolated Rust benchmark with optimized `rustc` from `scripts/benchmark_file_patch.rs`, then run each runtime/case in a separate process with `scripts/benchmark_file_patch.py`. Both runtimes read their own `/proc/self/status` VmHWM, avoiding unmatched/inherited `ru_maxrss` accounting. Python HWM includes its interpreter and imported source modules. The older `benchmark.jsonl` and `benchmark-final.jsonl` RSS fields are superseded and must not be used for memory comparisons; `benchmark-metadata.json` records why. Timing excludes process startup, imports, disk, authorization and artifact registration.

Representative measured medians (same executor; not full-server results):

| Input | Native | Upstream Python |
|---|---:|---:|
| 4 KiB exact | 2.32 µs | 4.35 µs |
| 1 MB exact | 526.5 µs | 431.6 µs |
| 64 KiB line-trimmed | 80.5 µs | 964.3 µs |
| Unicode typography edit | 7.18 µs | 38.7 µs |
| Similarity edit | 17.7 µs | 67.0 µs |

The native planner was faster on four of five representative cases; the 1 MB exact case was about 22% slower and is not presented as an improvement. Native benchmark HWM was roughly 1.2–3.1 MiB versus Python 15–19 MiB. An explicitly capped adversarial case rejected 20/20 requests, median 163 µs, p95 239 µs. These measurements are not a production memory/latency claim, and the frozen production release remains unchanged.
