-- Align the persisted Task shape with the v1 tri-state priority contract.
-- Existing 0/1 values remain false/true; new writes may use NULL.

DROP INDEX IF EXISTS idx_tasks_user_updated;
DROP INDEX IF EXISTS idx_tasks_user_active_due;
DROP INDEX IF EXISTS idx_tasks_project_active;

ALTER TABLE tasks RENAME TO tasks_legacy_0011;

CREATE TABLE tasks (
    id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    project_id TEXT,
    title TEXT NOT NULL,
    notes TEXT,
    task_type TEXT NOT NULL DEFAULT 'task'
        CHECK (task_type IN ('assignment', 'project', 'daily', 'task')),
    important INTEGER CHECK (important IS NULL OR important IN (0, 1)),
    urgent INTEGER CHECK (urgent IS NULL OR urgent IN (0, 1)),
    completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1)),
    completed_at TEXT,
    due TEXT,
    due_time TEXT,
    recurrence_rule TEXT,
    recurrence_until TEXT,
    reminder_minutes INTEGER,
    source TEXT,
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (project_id) REFERENCES projects (id) ON DELETE SET NULL,
    CHECK (completed = 0 OR completed_at IS NOT NULL),
    CHECK (reminder_minutes IS NULL OR reminder_minutes >= 0)
);

INSERT INTO tasks (
    id, user_id, project_id, title, notes, task_type, important, urgent,
    completed, completed_at, due, due_time, recurrence_rule,
    recurrence_until, reminder_minutes, source, deleted_at, created_at,
    updated_at, version
)
SELECT
    id, user_id, project_id, title, notes, task_type, important, urgent,
    completed, completed_at, due, due_time, recurrence_rule,
    recurrence_until, reminder_minutes, source, deleted_at, created_at,
    updated_at, version
FROM tasks_legacy_0011;

DROP TABLE tasks_legacy_0011;

CREATE INDEX idx_tasks_user_updated
    ON tasks (user_id, updated_at, id);

CREATE INDEX idx_tasks_user_active_due
    ON tasks (user_id, deleted_at, completed, due, due_time);

CREATE INDEX idx_tasks_project_active
    ON tasks (project_id, deleted_at, updated_at);

-- The pre-v1 server stored the entire recurrence request in recurrence_rule.
-- Keep only values that have the v1 object shape and split them into the
-- canonical rule/until columns. Invalid legacy values are intentionally
-- cleared instead of being emitted as an incompatible recurrence payload.
UPDATE tasks
SET recurrence_until = json_extract(recurrence_rule, '$.until'),
    recurrence_rule = json_extract(recurrence_rule, '$.rule')
WHERE recurrence_rule IS NOT NULL
  AND json_valid(recurrence_rule)
  AND json_type(recurrence_rule, '$.rule') = 'text'
  AND json_type(recurrence_rule, '$.until') = 'text';

UPDATE tasks
SET recurrence_rule = NULL,
    recurrence_until = NULL
WHERE recurrence_rule IS NOT NULL
  AND (
      recurrence_until IS NULL
      OR recurrence_rule NOT LIKE 'FREQ=%'
      OR recurrence_until NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
      OR length(recurrence_rule) = 0
  );
