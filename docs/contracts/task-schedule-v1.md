# Task / Schedule Contract v1

This document records the A01 semantic contract. The machine-readable field
shape lives in [`protocol/contracts/domain`](../../protocol/contracts/domain).

## Naming and compatibility

- `Task` means an actionable item with an optional deadline.
- `Schedule` means a concrete time interval.
- `CalendarEvent` remains a storage and HTTP compatibility name in v1.
- The sync wire value remains `calendar_event` in v1; this is not the domain name.
- `/api/v1/schedules` may be added as the canonical route, while
  `/api/v1/calendar-events` remains available for one migration cycle.

## Shared semantics

- IDs are opaque strings on the wire. New offline-created entities use UUIDv7;
  clients keep the same ID after synchronization.
- `createdAt`, `updatedAt`, and `deletedAt` use RFC 3339 timestamps.
- Entity `version` is the server optimistic-concurrency version and starts at 1.
- `baseVersion` is a write request field and identifies the server version the
  client edited; it is not part of the entity response.
- `remoteVersion` and `localRevision` are client-local fields, not public Domain
  fields.
- Deletion is a tombstone mutation; physical deletion is not part of v1 sync.

## Task

- `due` is a calendar date and does not create a Schedule.
- `dueTime` is a local wall-clock time and is valid only with `due`.
- `important` and `urgent` are tri-state: `null` means unclassified.
- `completed = false` requires `completedAt = null`.
- `completed = true` requires a non-null `completedAt` selected by the server.
- `recurrence` is either null or `{rule, until}`, where `rule` is an RFC 5545
  RRULE string and `until` is a calendar date.

## Schedule

- `startAt` and `endAt` are timezone-aware RFC 3339 timestamps.
- `startAt` must be earlier than `endAt`.
- Schedule has no `completed`, `important`, `urgent`, or `due` semantics.
- `source`, `externalId`, `taskId`, and `projectId` are not part of the v1
  public Schedule shape until they have an end-to-end implementation.

## A01 non-goals

- Conversation, Message, and Attachment contracts.
- Agent Gateway v1 changes.
- Database table renaming.
- Automatic conflict merging or CRDTs.
- Server `main.rs` modularization.
