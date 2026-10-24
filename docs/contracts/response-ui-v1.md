# Orialis response UI v1

Assistant replies may mix ordinary Markdown with closed code fences whose language is exactly `orialis-ui`. Each fence contains one JSON document. The document is stored unchanged in the ordinary message `content`; existing Gateway replies, final stream snapshots, sync and history carry the same content. No database migration or separate UI event is required.

Use this format when interaction helps a comparison, data summary or plan. Simple answers remain ordinary text. The mobile implementation uses existing Lumina components and does not execute generated HTML or JavaScript.

## Document

See [the shared all-components example](response-ui-v1.example.json). Required fields are `version: 1`, a nonempty readable `fallback`, and `blocks`. `title` is optional. Each block has `type`, optional `title`, and `items`:

| Type | Item fields | Behavior |
| --- | --- | --- |
| `metrics` | `label`, string `value`, optional `detail` | Selectable values and explanatory labels |
| `chart` | `label`, finite numeric `value` | Horizontal bars with explicit signed values; block may have `unit` |
| `tabs` | `label`, `content` | Tap to switch plain-text content |
| `checklist` | `label`, boolean `checked` | Local presentation; does not complete or save server tasks |
| `svg` | `label`, `source` | Static native SVG drawing with zoom and copy-source controls |
| `choices` | `label`, `prompt` | Appends a suggested follow-up to the existing draft; user sends explicitly |
| `diagram` | `id`, `label`, optional `detail`, `parent` | Native labelled flow, mindmap or relationship graph; node details and zoom |
| `math` | `label`, TeX `source` | Formula rendering, source copying and readable error fallback |
| `plot` | `label`, `points: [{x,y}]` | Line/scatter/pie charts with series selection and value inspection |
| `timeline` | `label`, optional `time`, `detail` | Ordered schedule or milestone preview |
| `simulation` | `label`, `kind`, optional `terms`, `amplitude`, `frequency` | Native sine/Fourier plot with live parameter controls |
| `form` | `id`, `label`, `kind`, optional initial `value` and constraints | Text/date/single/multiple choice/sliders; validated results fill the composer |
| `table` | `label`, `cells`; block `columns` | Search, sort, copy and export CSV |
| `sources` | `label`, `url`, optional `excerpt`, `sourceId` | Expand source excerpts and open links on tap |
| `diff` | `label`, `before`, `after` | Expand text/code differences and copy proposed text |
| `media` | `label`, attachment `id`, `mimeType`, optional `name` | Authenticated image/PDF/text/file preview, save and share |
| `actions` | `label`, `id`, `kind`, `title` and creation fields | Explicit confirmation, local task/schedule creation, receipt and sync status |

Maximum UTF-8 document size is 32,768 bytes; 1–12 blocks and 1–12 items per block. Character limits: document/block title 80, fallback 4000, label 120, metric value 120, detail 240, tab content 4000, prompt 1000, unit 32, SVG source 16000. Strings must be nonempty when provided. The phone validates these limits before rendering.

See [the extended example](response-ui-v1.extended.example.json) for all eleven
new block types. The original shared example remains the six-type compatibility
fixture. Together the two examples cover the advertised vocabulary; they are
separate documents because the per-document block limit remains twelve.

## Extended block constraints

- `diagram`: optional `layout` is `flow` (default), `mindmap` or `graph`. Node IDs
  are unique strings of at most 40 characters. Optional parent IDs must exist and
  form an acyclic hierarchy. Optional `edges` has at most 24 `{from,to,label?}`
  entries referencing existing IDs, with labels at most 80 characters. Node
  details are at most 1000 characters. Labels are native text, including Chinese.
- `math`: each source is nonempty TeX up to 4000 characters, without `$`
  delimiters. Invalid TeX shows copyable source rather than breaking the message.
- `plot`: required block `kind` is `line`, `scatter` or `pie`. Each series has
  1–120 points, finite numeric coordinates with absolute values at most 1e6.
  Pie slices use each series' sum of `y`; values must be nonnegative with a
  positive combined total. Numerical data remains available below the chart.
- `timeline`: optional `time` is an ISO8601 timestamp; `detail` is at most 1000
  characters. Display order follows the authored item order.
- `simulation`: exactly one item with `kind: sine|fourier`; optional `terms` is an
  integer 1–25, `amplitude` and `frequency` are numbers 0.1–5. Sine plots use
  `A*sin(f*x)`; Fourier plots sum odd harmonics of a square wave. Sliders change
  the native plot. No generated expression or script is evaluated.
- `form`: unique IDs match `[A-Za-z][A-Za-z0-9_-]{0,39}`. Required `kind` is `text`,
  `date`, `select`, `multiselect` or `slider`; `required` is an optional boolean.
  Text values have at most 1000 characters; dates strictly use `YYYY-MM-DD`.
  Selection fields require 1–12 unique nonempty string `options` up to 120
  characters; initial values must belong to those options. Slider `min < max`
  must be finite with absolute bounds at most 1e6; initial values must be in
  range. Block `prompt` is an optional prefix up to 1000 characters. Submission
  validates fields and appends a plain-text summary to the user's existing draft;
  it does not send a message. Local field state lasts only in the current view.
- `table`: block `columns` contains 1–8 nonempty headings up to 120 characters.
  Each row's `cells` must match column count; cells are strings up to 1000
  characters (empty allowed) or finite numbers with absolute values at most 1e12.
  Search and sorting affect displayed/exported rows. CSV strings are quoted and
  spreadsheet formula prefixes are escaped; source JSON is not modified.
- `sources`: HTTP(S) URLs up to 2000 characters require a host, no credentials or
  whitespace. Optional `excerpt` is up to 4000 characters and `sourceId` up to
  120. Opening is explicit; displaying a card does not verify its assertions.
- `diff`: `before` and `after` are strings up to 4000 characters each (empty
  allowed). The card does not apply code or file changes.
- `media`: attachment IDs match `[a-zA-Z0-9_-]{1,160}`. `mimeType` is required up
  to 120 characters; optional `name` up to 240. Reuses the authenticated attachment
  download path, image zoom, PDF page viewer, text preview, save and explicit
  system share. No model-provided filesystem path or arbitrary download URL.
- `actions`: IDs use the same bounded ID grammar and are unique within a block.
  `kind` is `task` or `schedule`, title up to 240 characters, optional notes up to
  4000 and location up to 240. A task may have strict `due: YYYY-MM-DD`; a schedule
  requires explicit-timezone `startAt` and `endAt`, with start before end.

## Action lifecycle

Generated action cards are creation proposals. Streaming cards and content
without a persisted message identity cannot create records. Tapping a completed
card opens a review dialog; cancellation writes nothing. Confirmation uses the
existing local-first repository to create the entity and outbox entry, plus an
action receipt in the same database transaction. Readback reports pending local
sync, synced, conflict or later deletion; it never equates local creation to
server acceptance. The receipt is scoped by account/server, persisted message,
fenced document and item payload, preventing repeated confirmation or reopening
from creating a second record. These controls cannot delete or modify records.

Fenced content remains opaque to the server; no message/database migration is
needed. This is an additive v1 vocabulary extension. Older v1 clients retain
their existing selectable-code fallback for unknown types. Client, discovery and
Hermes guidance should be released together.

## SVG drawing subset

Each `svg` item contains a descriptive `label` and standalone SVG `source`. The
client renders it with `flutter_svg` on a bounded canvas; users can zoom/pan and
copy the original SVG source. The label remains readable outside the drawing.
The document fallback must also explain the diagram's meaning.

The root must be `svg` with `xmlns="http://www.w3.org/2000/svg"` and a `viewBox`
containing four finite numbers. ViewBox width and height must be positive and
at most 10000. Each source may contain at most 256 elements. Supported elements are `svg`, `g`, `defs`, `path`, `rect`, `circle`,
`ellipse`, `line`, `polyline`, `polygon`, `linearGradient`, `radialGradient`, `stop`,
`clipPath`, `title` and `desc`. This is a static drawing subset, not full browser
SVG. Text and tspan are unsupported: convert lettering to paths or use the item
label, block title and document fallback for readable descriptions.

Only the client's explicit drawing-attribute allowlist is accepted. Scripts,
style elements/attributes, event handlers, images, `use`, `foreignObject`,
animation and external resources are rejected. `url(...)` references are allowed
only as `#local` references in `fill`, `stroke` and `clip-path`. Invalid SVG keeps
the message in the existing selectable-code fallback rather than dropping it.
No remote resource is fetched by the SVG renderer.

Older v1 clients treat the new block type as unsupported content and show the
ordinary selectable-code fallback. Update the client, service discovery and
Hermes plugin together for automatic SVG generation.

## Lifecycle and compatibility

- Only assistant output opts into UI rendering. A user's pasted example remains text.
- An incomplete `orialis-ui` fence shows “正在生成交互内容…”. Completed fences can render while the rest of the answer streams; follow-up choices activate after stream completion.
- The completed persisted reply replaces its corresponding stream using the existing message-ID handoff.
- Unsupported positive versions show `fallback`; malformed v1 documents remain selectable code. Ordinary code fences retain their existing rendering and copy behavior.
- Conversation previews, quotes, text selection, copying and transcript export substitute the authored fallback for valid UI fences. Stored content remains unchanged.
- Tab selection and checklist edits survive rebuilds of the current card. Leaving/recreating the view restores the authored initial state; local interaction is not synchronized across devices.
- Hermes receives generation guidance through its supported `platform_hint` system context, keeping inbound user text and native retry identity intact. The HTTP capabilities response and the plugin capability tool expose `response_ui` with format, version, block types and limits.

Provide a useful introduction outside the fence and an accurate fallback covering the card's information. UI formatting is not evidence that the underlying numbers are correct.
