# Intelligent UI extended capabilities — 2026-10-25

Status: implemented and locally verified on `codex/orialis-optimize-20261024` in
`repo-latest`. No production deployment, device installation, commit or push.

## Delivered behavior

The content-fence vocabulary grows from six to seventeen block types. The
original six remain compatible. All requested additions are connected to the
assistant renderer, generation guidance, discovery and persisted message path.

| Capability | Implementation and actual interaction |
| --- | --- |
| Structure diagrams | Native flow/mindmap/relationship layouts, Chinese node/edge labels, pan/zoom, node detail dialogs |
| Mathematical formulas | Native TeX rendering, copy source, readable invalid-formula fallback |
| Interactive charts | Line/scatter/pie, series selection, touch value inspection and expandable numerical data |
| Forms | Text/date/date picker/single/multiple selections/sliders, required/typed validation, append results to existing composer draft without sending |
| Interactive tables | Numeric/text sorting, search, full row detail dialog, current filtered/sorted CSV copy/export with UTF-8 BOM |
| Timelines | Authored milestones or schedule previews with time and details |
| Source cards | Source identifiers, expandable excerpts, explicit external link opening and URL copying |
| Images and files | Authenticated lazy attachment access, image gallery navigation and zoom, multipage PDF rendering, text preview, file save and explicit system share |
| Code/text differences | Common prefix/suffix context, expanded added/deleted sections, copy proposed result |
| Parameter demonstrations | Native sine and odd-harmonic Fourier square-wave plots; amplitude/frequency/term controls and reset; no arbitrary evaluation |
| Task/schedule cards | Preview then confirmation, real local repository/outbox creation, persistent deduplication, account-safe receipt readback and subsequent sync/deletion state |

The [contract](../contracts/response-ui-v1.md), [extended fixture](../contracts/response-ui-v1.extended.example.json)
and [architecture decision](../decisions/20261025-intelligent-ui-native-blocks.md)
record field shapes, limits, lifecycle and compatibility. Existing opaque message
transport and database schema remain in use. The extended fixture uses eleven
blocks, retaining the twelve-block and 32768-byte document limits.

![Rendered native diagram, formula, plot and interactive table](assets/intelligent-ui-extended-preview.png)

## Verification

- Combined Flutter acceptance: **61 tests passed** across eleven files, covering
  all new blocks, old SVG/UI behavior, Markdown and attachment account boundaries.
- Included nine visual tests, nine interactive tests, eight action/media tests,
  five extended parser/render/identity tests and one real saved-chat restoration
  test. The saved-chat test verifies all eleven new types survive persistence and
  reopening, with a stable action scope, draft preservation and no implicit send
  or task creation.
- Actions use a real in-memory database/repository/outbox: confirmation cancel,
  failure/retry, simultaneous duplicate creation, reopening, deleted-entity
  suppression and identity-switch transaction rollback are exercised.
- Authenticated loopback downloads verify attachment bytes and share dispatch
  success/failure. Gallery switching clears old bytes and invalidates on account
  change. A generated two-page PDF is opened and each page rendered by native
  PDFium. The test points to Flutter's generated native library; production uses
  the normal viewer/native-assets path.
- Hermes response generation/discovery: **3 tests passed** in the installed
  Hermes environment. Rust discovery: **1 test passed**.
- Focused Flutter analysis passed without issues. Scoped whitespace checks passed
  while retaining existing CRLF lockfile endings.
- Android arm64 debug build passed. The APK includes `libpdfium.so`, its pdfrx
  native gate and twenty bundled KaTeX font assets. Local artifact:
  `mobile/build/app/outputs/flutter-apk/app-debug.apk`.
- Final rendered preview was visually inspected with actual Chinese, KaTeX and
  Material icon fonts loaded. After the final theme-font adjustment, all fourteen
  visual/extended tests passed again; native build and focused analysis were
  repeated for that final source state.

Integration testing found and fixed two composition issues: a native table must
not ask LuminaButton's LayoutBuilder for intrinsic dimensions, and nested native
ExpansionTiles need a Material ancestor inside the card decoration. Independent
review also caught an account-switch race; action creation now captures one
identity key and rolls back the complete transaction on identity invalidation.

## Boundaries and remaining acceptance

This is local implementation acceptance. Production model output, server rollout,
physical Android interaction, native system sharing destinations and iOS/Windows
builds were not exercised. Task/schedule cards report local pending sync until
actual local state becomes synced; they do not fabricate cloud confirmation.
Forms remain view-local, simulation supports the two implemented functions, and
static SVG keeps its earlier bounded subset. Labelled diagrams render native
text instead of relying on unsupported SVG text elements.

The global coder Role owns the assigned implementation paths. The user explicitly
authorized these eleven capability groups; three independent implementation
groups handled visuals, interactions and action/media, with parent integration
and independent read-only review. No other Role/task ownership metadata is
present in this checkout. Startup checked project rules and shared `aw-orialis`
recall; project state/roadmap/task/memory files are absent as recorded in the SVG
report. This scoped acceptance report supplies current delivery state. Existing
unrelated dirty files were preserved.

Sources: user capability assessment and explicit implementation request; current
source and contract; actual local Flutter/Hermes/Rust/build evidence; independent
review. Test/build logs for this run are in `/tmp/orialis-intelligent-ui-*.log`.
