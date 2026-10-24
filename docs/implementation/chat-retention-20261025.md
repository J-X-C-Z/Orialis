# Chat retention and bulk deletion

Source: user request / 2026-10-25. Implementation and verification: current `repo/` source.

The Web chat page now has a bulk-selection mode with select-all, a confirmation step, and per-conversation deletion using the existing version-checked API. The default conversation cannot be selected. Successful items disappear immediately; failed items stay selected so the user can retry.

The server soft-deletes non-default conversations after seven days without message activity. Activity is based on the latest message timestamp; a conversation with no messages uses its `updated_at`. Cleanup runs hourly for all accounts and again when that account loads its conversation list. The existing deleted-at tombstone and version behavior are preserved.

Verification: Web tests 22/22 passed, Web production build passed, the focused server retention test passed, and `git diff --check` passed. No deployment was performed.
