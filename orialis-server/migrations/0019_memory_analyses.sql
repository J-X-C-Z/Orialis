-- Background screen-memory results never become conversations or chat messages.
CREATE TABLE memory_analyses (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    fingerprint TEXT NOT NULL,
    request_id TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('analyzing', 'completed', 'failed')),
    content TEXT,
    error TEXT,
    started_at INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
);
