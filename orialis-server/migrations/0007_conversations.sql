CREATE TABLE conversations (
    id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    is_default INTEGER NOT NULL DEFAULT 0 CHECK (is_default IN (0, 1)),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    deleted_at TEXT,
    PRIMARY KEY (user_id, id),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_conversations_one_default
    ON conversations (user_id) WHERE is_default = 1 AND deleted_at IS NULL;
CREATE INDEX idx_conversations_user_updated
    ON conversations (user_id, deleted_at, updated_at, id);
