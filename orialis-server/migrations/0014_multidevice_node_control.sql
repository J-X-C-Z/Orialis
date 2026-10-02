CREATE TABLE IF NOT EXISTS node_pairings (
    pairing_id TEXT PRIMARY KEY,
    pairing_secret_hash TEXT NOT NULL,
    confirmation_code_hash TEXT NOT NULL,
    identity_json TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('pending_confirmation','confirmed','rejected','completed','expired')),
    account_id TEXT REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    confirm_attempts INTEGER NOT NULL DEFAULT 0,
    CHECK ((state IN ('confirmed','rejected','completed') AND account_id IS NOT NULL) OR state IN ('pending_confirmation','expired'))
);

CREATE INDEX IF NOT EXISTS idx_node_pairings_expiry ON node_pairings(state, expires_at);
CREATE INDEX IF NOT EXISTS idx_node_pairings_account ON node_pairings(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS nodes (
    device_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    display_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    node_version TEXT NOT NULL,
    credential_hash TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    presence_state TEXT NOT NULL DEFAULT 'unknown' CHECK (presence_state IN ('unknown','online','offline')),
    revoked_at TEXT,
    revocation_version INTEGER NOT NULL DEFAULT 0 CHECK (revocation_version >= 0)
);

CREATE INDEX IF NOT EXISTS idx_nodes_account ON nodes(account_id, created_at DESC);

CREATE TABLE IF NOT EXISTS node_events (
    event_cursor INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id TEXT NOT NULL UNIQUE,
    account_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES nodes(device_id) ON DELETE CASCADE,
    sequence INTEGER NOT NULL CHECK (sequence >= 1),
    occurred_at TEXT NOT NULL,
    event_type TEXT NOT NULL CHECK (event_type IN ('node.presence_changed','node.revoked','capability.changed','approval.updated')),
    request_id TEXT,
    payload_json TEXT NOT NULL,
    UNIQUE(device_id, sequence)
);

CREATE INDEX IF NOT EXISTS idx_node_events_account_cursor ON node_events(account_id, event_cursor);
