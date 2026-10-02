# Android Lumina and AI chat — 2026-09-26

Source: user-confirmed design interview on 2026-09-26; implementation TASK-016.

## Accepted behavior

- Shared top bars and bottom navigation use clipped translucent blur; visual height shrinks without shrinking touch targets. Dragging a selection into its boundary compresses it before returning.
- High-performance mode prioritizes frame time; normal mode balances clarity and cost. The implemented filter is Flutter ImageFilter.blur with a small sigma, not a custom downsample or Dual Kawase shader. Adaptive degradation and reduced transparency/motion remain supported.
- Four-quadrant tasks retain title/completion/necessary time with compact spacing. Task/project order persists and syncs; manual order can be reset. Moving a task between quadrants changes importance/urgency and offers undo.
- Chat composer follows Android IME through the shell's single inset owner. System back dismisses the keyboard/overlay first, then details before leaving a primary page.
- Messages retain reference ID, text snapshot and role; Hermes receives an explicitly delimited quotation plus the user's new text. The gateway reply_to correlation field retains its existing response-correlation meaning.
- Chat reply by swipe or long press, quote preview/cancel, copy/select text, and jump to original. Attachment quotes describe attachment names rather than pretending image bytes were sent again.
- Pinned conversations are reorderable; normal conversations retain recency sorting.

## Hermes commands

Checked the locally installed Hermes implementation, not an assumed slash-command list:

- `hermes_cli/commands.py` COMMAND_REGISTRY and cli_only flags
- `gateway/run_inbound.py` canonical command dispatch
- `gateway/slash_commands_model.py`, `slash_commands_status.py`, `slash_commands_session.py`, `slash_commands.py`

The plus menu exposes `/status`, `/model` (list), editable `/model <name>` (session by default), `/compress`, `/resume`, editable `/title <name>`, and `/help`. Reset uses `/reset` after explicit confirmation; `/new` is its alias, not a separate context operation. `/stop` and `/retry` belong beside the running/failed turn. Model availability and command execution depend on the connected Hermes installation; registry support is not evidence of successful live execution.

CLI-only commands such as `/clear`, `/config`, `/tools`, `/cron`, `/plugins` are excluded. The custom command composer remains available. Prompt shortcuts fill the draft for review rather than immediately sending it. Changing a Hermes session title is distinct from renaming an Orialis conversation.

## Validation

See TASK-016 and project state for actual test/build outcomes. No deployment, live conversation reset or model change is part of development validation.
