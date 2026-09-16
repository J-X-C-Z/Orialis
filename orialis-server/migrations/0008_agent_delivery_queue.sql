-- Durable delivery queue for mobile messages waiting for an Orialis Agent.
-- A row is removed only after the assistant reply is persisted.
CREATE TABLE agent_delivery_queue (
    message_id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at TEXT NOT NULL,
    last_error TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (message_id) REFERENCES messages (id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX idx_agent_delivery_due
    ON agent_delivery_queue (next_attempt_at, created_at, message_id);

CREATE INDEX idx_agent_delivery_user
    ON agent_delivery_queue (user_id, next_attempt_at, created_at);
