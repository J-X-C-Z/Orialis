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
| `choices` | `label`, `prompt` | Appends a suggested follow-up to the existing draft; user sends explicitly |

Maximum UTF-8 document size is 32,768 bytes; 1–12 blocks and 1–12 items per block. Character limits: document/block title 80, fallback 4000, label 120, metric value 120, detail 240, tab content 4000, prompt 1000, unit 32. Strings must be nonempty when provided. The phone validates these limits before rendering.

## Lifecycle and compatibility

- Only assistant output opts into UI rendering. A user's pasted example remains text.
- An incomplete `orialis-ui` fence shows “正在生成交互内容…”. Completed fences can render while the rest of the answer streams; follow-up choices activate after stream completion.
- The completed persisted reply replaces its corresponding stream using the existing message-ID handoff.
- Unsupported positive versions show `fallback`; malformed v1 documents remain selectable code. Ordinary code fences retain their existing rendering and copy behavior.
- Conversation previews, quotes, text selection, copying and transcript export substitute the authored fallback for valid UI fences. Stored content remains unchanged.
- Tab selection and checklist edits survive rebuilds of the current card. Leaving/recreating the view restores the authored initial state; local interaction is not synchronized across devices.
- Hermes receives generation guidance through its supported `platform_hint` system context, keeping inbound user text and native retry identity intact. The HTTP capabilities response and the plugin capability tool expose `response_ui` with format, version, block types and limits.

Provide a useful introduction outside the fence and an accurate fallback covering the card's information. UI formatting is not evidence that the underlying numbers are correct.
