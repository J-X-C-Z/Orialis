-- Stable source-ID mappings used by the one-time Fangcun importer.
-- This table is intentionally separate from sync_events: historical import is
-- a batch operation and must not masquerade as live client mutations.
CREATE TABLE fangcun_id_map (
    user_id TEXT NOT NULL,
    source_kind TEXT NOT NULL,
    source_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    PRIMARY KEY (user_id, source_kind, source_id),
    UNIQUE (user_id, target_id),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE TABLE migration_batches (
    id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    source TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('dry_run', 'completed', 'failed')),
    report_json TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX idx_fangcun_id_map_user_kind
    ON fangcun_id_map (user_id, source_kind, source_id);

CREATE INDEX idx_migration_batches_user_created
    ON migration_batches (user_id, created_at, id);
