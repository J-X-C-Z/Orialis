-- Account-owned source memories; both client sync and MCP edits share this store.
CREATE TABLE screen_memories (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    id TEXT NOT NULL,
    record_json TEXT NOT NULL CHECK(json_valid(record_json)),
    created_at TEXT NOT NULL,
    version INTEGER NOT NULL CHECK(version > 0),
    updated_at TEXT NOT NULL,
    deleted_at TEXT,
    PRIMARY KEY(user_id, id)
);
CREATE TABLE screen_memory_history (
    user_id TEXT NOT NULL,
    memory_id TEXT NOT NULL,
    version INTEGER NOT NULL,
    source TEXT NOT NULL CHECK(source IN ('device-sync', 'mcp')),
    change_reason TEXT NOT NULL,
    changed_fields TEXT NOT NULL CHECK(json_valid(changed_fields)),
    created_at TEXT NOT NULL,
    PRIMARY KEY(user_id, memory_id, version),
    FOREIGN KEY(user_id, memory_id) REFERENCES screen_memories(user_id, id) ON DELETE CASCADE
);

CREATE INDEX screen_memories_account_order ON screen_memories(user_id, created_at, id);
CREATE TABLE memory_images (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sha256 TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    mime_type TEXT NOT NULL,
    PRIMARY KEY (user_id, sha256)
);
