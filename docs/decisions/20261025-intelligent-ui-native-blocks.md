# Native Intelligent UI extensions

Date: 2026-10-25. Status: implemented locally, pending release/device acceptance.

## Context

The user requested every capability from the Intelligent UI assessment: labelled
structure diagrams, formulas, interactive plots, forms, tables with expanded rows,
timelines, sources, media/file previews, diffs, parameter demonstrations and
task/schedule creation cards. The existing v1 content-fence format already carries
opaque assistant JSON through message storage, history and streams.

## Decision

Extend v1 with eleven bounded native data blocks. Reuse the existing parser/view
and message persistence. Native diagram nodes render text directly, including
Chinese, rather than expanding the static SVG subset into a browser runtime.
Use flutter_math_fork for TeX, fl_chart for plots, pdfrx for authenticated PDF
bytes and share_plus for user-invoked file sharing. Form controls produce a
reviewable composer draft; simulation controls operate only on implemented
sine/Fourier functions. No generated JavaScript or arbitrary expression evaluation.

Creation cards carry a persisted message scope from saved replies or committed
stream IDs. Each fence gets a SHA256 content fingerprint. Creation confirms the
proposal, writes through EventRepository, and records an account/server/message/
payload-scoped receipt in existing SyncMetadata in the same transaction as the
entity and sync outbox. Captured identity is checked before committing; account
changes roll back. Local creation is reported distinctly from confirmed sync.
Deleted records retain their receipt so reopening cannot silently recreate them.

## Consequences

Old clients retain their unknown-block code fallback; client, Hermes guidance and
server discovery must be released together. Documents remain limited to 32768
UTF-8 bytes and twelve blocks, so the full vocabulary has two shared fixtures.
UI field state is view-local. Action receipts persist, with no new SQL migration.
PDF and share plugins add platform dependencies and therefore require a native
build as well as widget tests. Source provenance and chart accuracy still depend
on the actual agent/tool evidence; rendering does not certify the data.

Sources: user request in this chat; response-ui-v1 contract; current mobile source;
independent review of creation identity, transaction and parser integration.
