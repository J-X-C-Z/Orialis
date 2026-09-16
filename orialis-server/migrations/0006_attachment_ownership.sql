-- Bind an uploaded attachment to the conversation it was uploaded for and
-- retain a small idempotency response cache for safe client retries.
ALTER TABLE attachments ADD COLUMN conversation_id TEXT NOT NULL DEFAULT '';

CREATE INDEX idx_attachments_user_conversation
    ON attachments (user_id, conversation_id, created_at, id);

CREATE TABLE attachment_uploads (
    user_id TEXT NOT NULL,
    conversation_id TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    response_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (user_id, conversation_id, idempotency_key),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);
