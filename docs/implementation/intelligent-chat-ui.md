# Intelligent chat UI

The mobile chat uses a full-width reading surface for assistant replies, including live streams; user messages retain their bubbles. Assistant Markdown can contain native metrics, bar charts, tabs, local checklists, suggested follow-ups and static SVG drawings. SVG cards provide a full-screen zoom/pan viewer and source copying; see [SVG acceptance](intelligent-ui-svg-20261025.md) for supported drawing limits and verification. The implementation keeps the current Lumina theme, supports narrow screens and large text, and reuses the existing composer flow for follow-ups. Existing drafts are preserved and no choice sends automatically.

The [v1 contract](../contracts/response-ui-v1.md) and [shared example](../contracts/response-ui-v1.example.json) define the cross-language format. Server discovery and the Hermes system platform hint advertise the same bounded vocabulary. Raw message transport and persistence are reused rather than adding another message store or event protocol.

The [extended example](../contracts/response-ui-v1.extended.example.json) adds
native labelled structure diagrams, TeX formulas, line/scatter/pie plots,
timelines, sine/Fourier parameter demonstrations, forms, searchable/sortable tables
with expanded rows and CSV export, sources, text/code diffs, attachment galleries
and PDF/file previews, and confirmed task/schedule creation cards. Forms preserve
the user's draft; creation cards use the existing local repository and sync
outbox, with persistent receipts and actual state readback. See the [native-block
decision](../decisions/20261025-intelligent-ui-native-blocks.md).

## Runtime status and motion

A compact panel shows actual runtime state before the first token and can expand public progress summaries and tool steps. The refresh button waits for a response correlated to its request and conversation; it shows a timestamp only after success, keeps failures retryable and never sends a chat turn. Incoming lifecycle events supersede an earlier snapshot. The empty-conversation layout also includes this panel.

The gateway formalizes the plugin's `session.info`/`session.reply` request/reply messages and negotiates the `session.status` capability per connection. The service authorizes the conversation/device binding, queries that exact device and returns the existing mobile `session.status` event with `requestId`, `conversationId`, `status` and a public `message`. The adapter records real processing start/completion/error/cancellation, and queries do not invoke the model. Hidden reasoning and tool argument previews are excluded from the new progress frames. Old plugins immediately return status `unknown` and an upgrade explanation without dispatching a message or calling a model. Unavailable supported devices return an explicit failure rather than a fabricated completion.

Status changes crossfade and the process section expands using the existing 140 ms Lumina fast token and easing curve. Reduced motion bypasses the expansion animation. Token text is displayed immediately without replaying an entrance animation on each delta. These transitions use Flutter's built-in widgets and add no dependency.

## Rollout

Ship the updated mobile client, service and Hermes plugin together to enable automatic rich output. Existing messages and database layouts are compatible. Update the plugin package as a whole because `response_ui.py` is imported by its platform registration and capability tool; restart the relevant gateway after installing it. The server still stores malformed generated content as text so a rendering issue does not discard a reply.

This implementation does not include arbitrary generated apps or HTML/JavaScript
execution. Local checklist controls remain presentation-only; explicit action
cards can create local tasks/schedules after confirmation and report subsequent
sync state. Physical Android acceptance and production deployment are tracked
separately from local tests and build artifacts.

The [extended-capability acceptance report](intelligent-ui-expanded-20261025.md)
records the final test counts, rendered preview, Android build and remaining
device/release acceptance.

## Checks

Focused tests cover strict parsing, unsupported-version fallback, incomplete streams, original Markdown/code compatibility, local controls, narrow large-text layout, preserving drafts without sending, saved-message reopening, bubble-free assistant content, correlated refresh success/failure, stale snapshot supersession, reduced motion and interrupted expansion. Backend checks cover reply/history and stream fidelity, actual Hermes platform hints and processing hooks, and status authorization/protocol transport. The same all-components JSON fixture is consumed by mobile and backend tests.
