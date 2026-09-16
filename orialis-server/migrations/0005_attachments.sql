-- User-owned chat attachments. The access token is stored only as a hash;
-- the opaque download URL is returned once to the authenticated client.
ALTER TABLE messages ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';

CREATE TABLE attachments (
    id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    original_name TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL CHECK (size_bytes > 0),
    storage_path TEXT NOT NULL,
    access_token_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX idx_attachments_user_created
    ON attachments (user_id, created_at, id);
