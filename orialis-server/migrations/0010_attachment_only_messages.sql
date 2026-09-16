-- Attachment-only chat messages are valid: the message body may be empty when
-- the same row contains at least one canonical attachment.
PRAGMA foreign_keys = OFF;

CREATE TABLE messages_v10 (
    id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user'
        CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL
        CHECK (length(trim(content)) > 0 OR attachments_json <> '[]'),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    attachments_json TEXT NOT NULL DEFAULT '[]',
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

INSERT INTO messages_v10
    (id,user_id,conversation_id,role,content,created_at,updated_at,version,attachments_json)
SELECT id,user_id,conversation_id,role,content,created_at,updated_at,version,attachments_json
FROM messages;

DROP TABLE messages;
ALTER TABLE messages_v10 RENAME TO messages;

CREATE INDEX idx_messages_user_conversation_created
    ON messages (user_id, conversation_id, created_at, id);

CREATE INDEX idx_messages_user_updated
    ON messages (user_id, updated_at, id);

PRAGMA foreign_keys = ON;
