# Intelligent UI SVG drawing — 2026-10-25

Status: implemented locally; no production deployment or physical-device acceptance.

## Acceptance

Assistant `orialis-ui` replies can now include `svg` blocks with items containing
`label` and `source`. Each drawing appears on a neutral canvas with a readable
label. The user can open a full-screen viewer, pinch to zoom (1–8×), pan, close
the viewer, or copy the unchanged SVG source. Existing message storage, streaming,
history and transcript fallback are reused. A user-pasted example stays text.

The parser checks the static SVG element/attribute allowlists, required namespace
and viewBox, 16000-character source limit and 256-element limit. It rejects active
content and external resources. The overall 32768-byte JSON limit still applies.
Malformed XML retains selectable code; renderer failures show a readable message
and keep source copying available. Text/tspan are outside the supported subset;
use path lettering, item labels, block titles and accurate text fallbacks.

Hermes system guidance, Rust discovery, the cross-language fixture and the v1
contract advertise the new block consistently. Old v1 clients retain their
existing selectable-code fallback for unknown blocks.

## Verification

- Four SVG tests: shared six-component fixture; invalid/active/remote/oversized
  input rejection; narrow 240px layout at 2× text with clipboard and viewer controls;
  renderer failure recovery. Passed.
- Eighteen existing response UI, layout and saved-chat tests passed. This includes
  reopening the shared SVG-containing history fixture and preserving chat drafts.
- Hermes response UI tests: 3 passed in the actual Hermes environment.
- Rust response UI discovery test: 1 passed.
- Independent source review found a named-color false rejection; matching actual
  `url(...)` syntax fixed it, with a `burlywood` regression assertion.
- Focused Flutter analysis passed with no issues. Scoped whitespace checks passed
  with the lockfile's existing CRLF line endings preserved.

An initial mobile test launch collided with another Flutter command's generated
native-assets directory. A subsequent run completed. One new test initially left
the existing toast timer pending; it now advances past toast dismissal.

## Scope and coordination

User request: enrich Intelligent UI, explicitly including SVG drawing. Execution
uses the global `coder` Role's `assigned-task-paths`; the capability router selected
`codex` (`status=routed`). Mobile parser/view/tests/dependencies are the primary
work; an independent subagent handled contract, Hermes hint and Rust discovery,
then performed read-only mobile review. These paths are explicitly authorized by
the user request. Unrelated dirty work is preserved; nothing was committed/pushed.

Startup checked the project root and both source checkouts. Project-level
`project.yaml`, `state.md`, `roadmap.md`, `memory/summary.md`, `memory.db`, tasks and
Role overrides are absent in this local project. No missing historical state or
owner tasks were fabricated. Current implementation documentation, source and
shared `aw-orialis` recall were read. This scoped report records the delivery state
without bootstrapping an unrelated workspace structure.

Sources: current user request; `docs/implementation/intelligent-chat-ui.md`;
`docs/contracts/response-ui-v1.md`; mobile domain/presentation sources and test
results; Hermes response UI tests; Rust health discovery test.
