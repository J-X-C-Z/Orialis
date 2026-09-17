-- Frozen pre-A02.2 schema. This fixture must not depend on the v7 table models.
CREATE TABLE tasks (
  id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, notes TEXT, due TEXT,
  due_time TEXT, important INTEGER, urgent INTEGER,
  completed INTEGER NOT NULL DEFAULT 0, completed_at TEXT,
  reminder_minutes INTEGER, project_id TEXT, recurrence TEXT,
  version INTEGER NOT NULL DEFAULT 1, remote_version INTEGER NOT NULL DEFAULT 0,
  local_revision INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT,
  sync_status TEXT NOT NULL DEFAULT 'synced'
);
CREATE TABLE calendar_events (
  id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL, description TEXT,
  location TEXT, start_at TEXT NOT NULL, end_at TEXT NOT NULL,
  all_day INTEGER NOT NULL DEFAULT 0, reminder_minutes INTEGER,
  version INTEGER NOT NULL DEFAULT 1, remote_version INTEGER NOT NULL DEFAULT 0,
  local_revision INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT,
  sync_status TEXT NOT NULL DEFAULT 'synced'
);
CREATE TABLE messages (
  conversation_id TEXT NOT NULL, id TEXT NOT NULL, role TEXT NOT NULL,
  content TEXT NOT NULL, created_at TEXT NOT NULL,
  attachments_json TEXT NOT NULL DEFAULT '[]',
  sync_status TEXT NOT NULL DEFAULT 'synced',
  remote_version INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (conversation_id, id)
);
CREATE TABLE conversations (
  id TEXT NOT NULL PRIMARY KEY, title TEXT NOT NULL,
  type TEXT NOT NULL DEFAULT 'normal', created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1,
  remote_version INTEGER NOT NULL DEFAULT 0, deleted_at TEXT,
  sync_status TEXT NOT NULL DEFAULT 'synced'
);
CREATE TABLE sync_metadata (key TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE outbox_mutations (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, mutation_id TEXT NOT NULL UNIQUE,
  entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL,
  payload_json TEXT NOT NULL, base_version INTEGER,
  entity_revision INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT
);
INSERT INTO tasks (
  id, title, project_id, reminder_minutes, version, remote_version, local_revision,
  sync_status, created_at, updated_at
) VALUES ('old-task', 'queued task', 'p1', 15, 4, 3, 8,
  'pendingUpdate', '2026-09-17T00:00:00Z', '2026-09-17T00:00:00Z');
INSERT INTO calendar_events (
  id, title, start_at, end_at, reminder_minutes, version, remote_version,
  local_revision, created_at, updated_at
) VALUES ('old-event', 'schedule', '2026-09-18T01:00:00Z',
  '2026-09-18T02:00:00Z', 30, 2, 2, 5,
  '2026-09-17T00:00:00Z', '2026-09-17T00:00:00Z');
INSERT INTO conversations (id, title, created_at, updated_at)
VALUES ('c1', 'conversation', '2026-09-17T00:00:00Z', '2026-09-17T00:00:00Z');
INSERT INTO messages (conversation_id, id, role, content, created_at)
VALUES ('c1', 'message1', 'user', 'keep me', '2026-09-17T00:00:00Z');
INSERT INTO sync_metadata VALUES ('serverCursor', '42');
INSERT INTO outbox_mutations (
  mutation_id, entity_type, entity_id, operation, payload_json, base_version,
  entity_revision, status, attempt_count, last_error, created_at, updated_at
) VALUES ('stable-mutation', 'task', 'old-task', 'update',
  '{"title":"queued task"}', 3, 8, 'inFlight', 2, 'timeout',
  '2026-09-17T00:00:00Z', '2026-09-17T00:00:00Z');
PRAGMA user_version = 6;
