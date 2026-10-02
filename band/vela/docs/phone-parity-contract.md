# Phone non-chat projection, v1

Source: user / 2026-10-02 phone parity instruction; authoritative mobile/lib/core/database/app_database.dart, TaskRepository, EventRepository, ProjectRepository. This is an optional local Wear UI snapshot projection, not a new HTTP API or a verified Xiaomi SDK contract. Existing W0 envelope, chunk limits, durable ACK and scope semantics stay unchanged.

The optional `snapshot.view.organizer` contains:

- `schemaVersion: 1`, `today: YYYY-MM-DD`, optional `utcOffsetMinutes: integer` (phone local date, never inferred from UTC slicing).
- `tasks`: id, title, notes, due (local date or null), dueTime (HH:mm or null), important (nullable bool), urgent (nullable bool), completed (bool), reminderMinutes (integer or null), recurrence (stored JSON string or null), projectId, parentTaskId, scheduleId (nullable IDs), manualPosition (nullable integer). Keep Tasks separate from Schedules; one-level parentTaskId and scheduleId are mutually exclusive.
- `schedules`: id, title, description, location, startAt/endAt (existing RFC3339 values), allDay, important, reminderMinutes. Use phone utcOffsetMinutes for local display and [startAt,endAt) overlap for calendar days; preserve timezone semantics; do not turn a Task into a Schedule automatically.
- `projects`: id, name, goal, description, status, due, nextActionTaskId, manualPosition.
- `milestones`: id, projectId, title, due, completed, position.
- `profile`: displayName (non-secret), signedIn (bool), serverLabel (host-only, no userinfo/query/tokens). Do not serialize access tokens, credentials, conversations, messages, quotes or attachments.
- `sync`: status (observed string or unknown), lastSyncAt (observed ISO timestamp or null).
- `coverage`: tasks/schedules/projects/milestones each `{ included, total }`; `coverage.truncated: bool` (legacy organizer.truncated also accepted). The entire existing snapshot must remain <=16384 UTF8 bytes. A limited projection must be labelled as partial in the band.

Missing organizer or missing collections means no organizer data, never fallback to the old agent `view.tasks` as user Tasks. Existing commands/devices remain supplemental projections. Organizer collections represent phone source when received; mutation actions stay disabled for real phone/cache until a separately documented, authenticated operation interface is available. All mutations implemented for interface preview are explicit in-memory demo changes only, reset on demo disable/restart and identity revoke. No mutation replay or invented server endpoints.

Main band navigation aligns Today / Events / Calendar / Projects / My. No Chat route, conversation list, message list, agent chat, attachment or composer. Supplemental devices/connection diagnosis remain accessible under My. Preserve Fangcun visual tokens and app-global store/transport with replace navigation.
