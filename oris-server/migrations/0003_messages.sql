-- Persistent Chat V1 messages. Messages are deliberately separate from the
-- Agent gateway: storing a user message does not imply an Agent reply.
CREATE TABLE messages (
    id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'user'
        CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL CHECK (length(trim(content)) > 0),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX idx_messages_user_conversation_created
    ON messages (user_id, conversation_id, created_at, id);

CREATE INDEX idx_messages_user_updated
    ON messages (user_id, updated_at, id);
