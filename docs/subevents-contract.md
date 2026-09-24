# Child task and Schedule importance contract

This document defines the v1 API contract for a single child-task level and
Schedule importance. It extends the Task and Schedule shapes without changing
the existing resource routes or entity naming.

## Task relationships

Task responses include these nullable fields:

| JSON field | Type | Meaning |
| --- | --- | --- |
| `parentTaskId` | string or null | Parent task for a single-level child task |
| `scheduleId` | string or null | Schedule associated with a task |

The two references are mutually exclusive. A task may be a child of one task,
belong to one Schedule, or have neither relationship. A child task remains a
regular Task with its own due date, priority (`important` and `urgent`),
completion state, and lifecycle. These values are not inherited from its parent
or Schedule.

References must belong to the authenticated user. A task cannot refer to itself,
and child tasks cannot themselves have child tasks. This also rules out cycles.
The canonical task API uses camelCase JSON (`parentTaskId`, `scheduleId`) and
serializes responses in camelCase. For compatibility, task create and PATCH
requests also accept the snake_case aliases `parent_task_id` and `schedule_id`.
Clients should send camelCase. Stored or cross-service representations may use
snake_case.

Create requests may provide either reference. PATCH follows the existing partial
update convention: omitting a relationship preserves its value, while sending
explicit `null` clears it. Clients that do not know these fields can continue
creating and updating tasks without sending them.

Completing a parent Task completes all of its direct children. When a non-empty
set of direct children is all completed, the parent is completed automatically.
Reopening any child reopens the parent. Reopening the parent directly does not
change child completion states. These transitions apply to Tasks only; Schedule
has no completion state.

Deleting a Task soft-deletes its direct children in the same mutation. Deleting
a Schedule likewise soft-deletes all Tasks directly associated with it. A child
cannot have its own children, so these cascades are limited to one relationship
level.

## Schedule importance

Schedule and CalendarEvent responses include `important: boolean`. Creation
defaults it to `false` when omitted. PATCH omission preserves the stored value;
explicit `true` or `false` updates it. Existing `/api/v1/calendar-events`
clients remain compatible, and `/api/v1/schedules` is the canonical resource
name where available.

## Validation coverage

`tests/roadmap/test_live_subevents.py` exercises child task CRUD, Schedule
association, Schedule importance defaults and updates, patch omission versus
explicit null, completion propagation in both directions, parent reopening,
task and Schedule deletion cascades, camelCase and snake_case relationship
inputs, and invalid self, nested, cross-user, and dual associations. It uses the
existing `ORIALIS_ROADMAP_BASE_URL` local test-server setting.
