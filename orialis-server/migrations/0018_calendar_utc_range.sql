-- Compare RFC 3339 instants without rewriting stored timestamp strings.
-- SQLx runs this complete rebuild in one transaction. Invalid legacy rows abort
-- the copy and roll back the schema, triggers, data and migration record.
-- Preflight: scripts/check-calendar-utc-ranges.py --database PATH
-- Keep link triggers absent only inside this migration transaction: SQLite
-- validates their table references during ALTER TABLE ... RENAME.
-- Whole seconds never receive a fractional component. Offset arithmetic is
-- integer-only and supports the RFC 3339 range of -23:59 through +23:59.
-- Leap seconds use second 59 plus a separate ordered leap flag, matching chrono.
-- Fractional digits compare lexically after trimming trailing zeros, preserving
-- nanoseconds and arbitrary longer RFC 3339 fractions without numeric rounding.
DROP TRIGGER tasks_validate_links_insert;
DROP TRIGGER tasks_validate_links_update;
CREATE TABLE calendar_events_new (
    id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    location TEXT,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    all_day INTEGER NOT NULL DEFAULT 0 CHECK (all_day IN (0, 1)),
    reminder_minutes INTEGER,
    source TEXT,
    deleted_at TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    important INTEGER NOT NULL DEFAULT 0 CHECK (important IN (0, 1)),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    -- BEGIN CALENDAR_UTC_RANGE_CHECK
    CONSTRAINT calendar_events_utc_range CHECK (COALESCE((length(start_at)>=20 AND instr(start_at,char(0))=0
 AND (substr(start_at,1,4) || substr(start_at,6,2) || substr(start_at,9,2) || substr(start_at,12,2) || substr(start_at,15,2) || substr(start_at,18,2)) NOT GLOB '*[^0-9]*'
 AND substr(start_at,5,1)='-' AND substr(start_at,8,1)='-'
 AND substr(start_at,11,1) IN ('T','t',' ')
 AND substr(start_at,14,1)=':' AND substr(start_at,17,1)=':'
 AND date(substr(start_at,1,10),'+0 days')=substr(start_at,1,10)
 AND CAST(substr(start_at,12,2) AS INTEGER)<=23
 AND CAST(substr(start_at,15,2) AS INTEGER)<=59
 AND CAST(substr(start_at,18,2) AS INTEGER)<=60
 AND (lower(substr(start_at,-1))='z' OR
     (substr(start_at,-6,1) IN ('+','-') AND substr(start_at,-3,1)=':'
      AND (substr(start_at,-5,2)||substr(start_at,-2,2)) NOT GLOB '*[^0-9]*'
      AND CAST(substr(start_at,-5,2) AS INTEGER)<=23 AND CAST(substr(start_at,-2,2) AS INTEGER)<=59))
 AND (length(start_at)=19+(CASE WHEN lower(substr(start_at,-1))='z' THEN 1 ELSE 6 END) OR
     (substr(start_at,20,1)='.' AND length(start_at)>20+(CASE WHEN lower(substr(start_at,-1))='z' THEN 1 ELSE 6 END)
      AND (CASE WHEN substr(start_at,20,1)='.' THEN substr(start_at,21,length(start_at)-20-(CASE WHEN lower(substr(start_at,-1))='z' THEN 1 ELSE 6 END)) ELSE '' END) NOT GLOB '*[^0-9]*'))) AND (length(end_at)>=20 AND instr(end_at,char(0))=0
 AND (substr(end_at,1,4) || substr(end_at,6,2) || substr(end_at,9,2) || substr(end_at,12,2) || substr(end_at,15,2) || substr(end_at,18,2)) NOT GLOB '*[^0-9]*'
 AND substr(end_at,5,1)='-' AND substr(end_at,8,1)='-'
 AND substr(end_at,11,1) IN ('T','t',' ')
 AND substr(end_at,14,1)=':' AND substr(end_at,17,1)=':'
 AND date(substr(end_at,1,10),'+0 days')=substr(end_at,1,10)
 AND CAST(substr(end_at,12,2) AS INTEGER)<=23
 AND CAST(substr(end_at,15,2) AS INTEGER)<=59
 AND CAST(substr(end_at,18,2) AS INTEGER)<=60
 AND (lower(substr(end_at,-1))='z' OR
     (substr(end_at,-6,1) IN ('+','-') AND substr(end_at,-3,1)=':'
      AND (substr(end_at,-5,2)||substr(end_at,-2,2)) NOT GLOB '*[^0-9]*'
      AND CAST(substr(end_at,-5,2) AS INTEGER)<=23 AND CAST(substr(end_at,-2,2) AS INTEGER)<=59))
 AND (length(end_at)=19+(CASE WHEN lower(substr(end_at,-1))='z' THEN 1 ELSE 6 END) OR
     (substr(end_at,20,1)='.' AND length(end_at)>20+(CASE WHEN lower(substr(end_at,-1))='z' THEN 1 ELSE 6 END)
      AND (CASE WHEN substr(end_at,20,1)='.' THEN substr(end_at,21,length(end_at)-20-(CASE WHEN lower(substr(end_at,-1))='z' THEN 1 ELSE 6 END)) ELSE '' END) NOT GLOB '*[^0-9]*'))) AND ((CAST(strftime('%s', upper(substr(end_at,1,17)) || CASE WHEN substr(end_at,18,2)='60' THEN '59' ELSE substr(end_at,18,2) END) AS INTEGER) - CASE WHEN lower(substr(end_at,-1))='z' THEN 0 ELSE (CASE substr(end_at,-6,1) WHEN '-' THEN -1 ELSE 1 END)*(CAST(substr(end_at,-5,2) AS INTEGER)*3600+CAST(substr(end_at,-2,2) AS INTEGER)*60) END)>(CAST(strftime('%s', upper(substr(start_at,1,17)) || CASE WHEN substr(start_at,18,2)='60' THEN '59' ELSE substr(start_at,18,2) END) AS INTEGER) - CASE WHEN lower(substr(start_at,-1))='z' THEN 0 ELSE (CASE substr(start_at,-6,1) WHEN '-' THEN -1 ELSE 1 END)*(CAST(substr(start_at,-5,2) AS INTEGER)*3600+CAST(substr(start_at,-2,2) AS INTEGER)*60) END) OR ((CAST(strftime('%s', upper(substr(end_at,1,17)) || CASE WHEN substr(end_at,18,2)='60' THEN '59' ELSE substr(end_at,18,2) END) AS INTEGER) - CASE WHEN lower(substr(end_at,-1))='z' THEN 0 ELSE (CASE substr(end_at,-6,1) WHEN '-' THEN -1 ELSE 1 END)*(CAST(substr(end_at,-5,2) AS INTEGER)*3600+CAST(substr(end_at,-2,2) AS INTEGER)*60) END)=(CAST(strftime('%s', upper(substr(start_at,1,17)) || CASE WHEN substr(start_at,18,2)='60' THEN '59' ELSE substr(start_at,18,2) END) AS INTEGER) - CASE WHEN lower(substr(start_at,-1))='z' THEN 0 ELSE (CASE substr(start_at,-6,1) WHEN '-' THEN -1 ELSE 1 END)*(CAST(substr(start_at,-5,2) AS INTEGER)*3600+CAST(substr(start_at,-2,2) AS INTEGER)*60) END) AND ((CASE WHEN substr(end_at,18,2)='60' THEN '1' ELSE '0' END) || rtrim((CASE WHEN substr(end_at,20,1)='.' THEN substr(end_at,21,length(end_at)-20-(CASE WHEN lower(substr(end_at,-1))='z' THEN 1 ELSE 6 END)) ELSE '' END),'0')) COLLATE BINARY>=((CASE WHEN substr(start_at,18,2)='60' THEN '1' ELSE '0' END) || rtrim((CASE WHEN substr(start_at,20,1)='.' THEN substr(start_at,21,length(start_at)-20-(CASE WHEN lower(substr(start_at,-1))='z' THEN 1 ELSE 6 END)) ELSE '' END),'0')) COLLATE BINARY)),0)),
    -- END CALENDAR_UTC_RANGE_CHECK
    CHECK (reminder_minutes IS NULL OR reminder_minutes >= 0)
);
INSERT INTO calendar_events_new (id,user_id,title,description,location,start_at,end_at,all_day,reminder_minutes,source,deleted_at,created_at,updated_at,version,important) SELECT id,user_id,title,description,location,start_at,end_at,all_day,reminder_minutes,source,deleted_at,created_at,updated_at,version,important FROM calendar_events;
DROP TABLE calendar_events;
ALTER TABLE calendar_events_new RENAME TO calendar_events;
CREATE INDEX idx_calendar_events_user_start
    ON calendar_events (user_id, deleted_at, start_at, end_at, id);

CREATE INDEX idx_calendar_events_user_updated
    ON calendar_events (user_id, updated_at, id);


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
