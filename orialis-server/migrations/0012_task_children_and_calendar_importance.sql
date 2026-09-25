-- Tasks may link to one active same-user root task or one active calendar event.
-- Existing calendar rows remain unimportant; new schedule importance defaults false.
ALTER TABLE tasks ADD COLUMN parent_task_id TEXT;
ALTER TABLE tasks ADD COLUMN schedule_id TEXT;

CREATE INDEX idx_tasks_parent_active
    ON tasks (parent_task_id, deleted_at, id);

ALTER TABLE calendar_events
    ADD COLUMN important INTEGER NOT NULL DEFAULT 0 CHECK (important IN (0, 1));

CREATE TRIGGER tasks_validate_links_insert
BEFORE INSERT ON tasks
WHEN NEW.parent_task_id IS NOT NULL OR NEW.schedule_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.parent_task_id IS NOT NULL AND NEW.schedule_id IS NOT NULL
            THEN RAISE(ABORT, 'task parent and schedule are mutually exclusive')
        WHEN NEW.parent_task_id = NEW.id
            THEN RAISE(ABORT, 'task cannot parent itself')
        WHEN NEW.parent_task_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM tasks p
            WHERE p.id=NEW.parent_task_id AND p.user_id=NEW.user_id
              AND p.deleted_at IS NULL AND p.parent_task_id IS NULL AND p.schedule_id IS NULL
        ) THEN RAISE(ABORT, 'parent task must be an active root owned by the user')
        WHEN NEW.schedule_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM tasks c
            WHERE c.parent_task_id=NEW.id AND c.user_id=NEW.user_id AND c.deleted_at IS NULL
        ) THEN RAISE(ABORT, 'task with children cannot be assigned a schedule')
        WHEN NEW.schedule_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM calendar_events e
            WHERE e.id=NEW.schedule_id AND e.user_id=NEW.user_id AND e.deleted_at IS NULL
        ) THEN RAISE(ABORT, 'schedule must be active and owned by the user')
    END;
END;

CREATE TRIGGER tasks_validate_links_update
BEFORE UPDATE OF parent_task_id,schedule_id ON tasks
WHEN NEW.parent_task_id IS NOT NULL OR NEW.schedule_id IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.parent_task_id IS NOT NULL AND NEW.schedule_id IS NOT NULL
            THEN RAISE(ABORT, 'task parent and schedule are mutually exclusive')
        WHEN NEW.parent_task_id = NEW.id
            THEN RAISE(ABORT, 'task cannot parent itself')
        WHEN NEW.parent_task_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM tasks p
            WHERE p.id=NEW.parent_task_id AND p.user_id=NEW.user_id
              AND p.deleted_at IS NULL AND p.parent_task_id IS NULL AND p.schedule_id IS NULL
        ) THEN RAISE(ABORT, 'parent task must be an active root owned by the user')
        WHEN NEW.parent_task_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM tasks c
            WHERE c.parent_task_id=NEW.id AND c.deleted_at IS NULL
        ) THEN RAISE(ABORT, 'task with children cannot become a child')
        WHEN NEW.schedule_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM tasks c
            WHERE c.parent_task_id=NEW.id AND c.user_id=NEW.user_id AND c.deleted_at IS NULL
        ) THEN RAISE(ABORT, 'task with children cannot be assigned a schedule')
        WHEN NEW.schedule_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM calendar_events e
            WHERE e.id=NEW.schedule_id AND e.user_id=NEW.user_id AND e.deleted_at IS NULL
        ) THEN RAISE(ABORT, 'schedule must be active and owned by the user')
    END;
END;
