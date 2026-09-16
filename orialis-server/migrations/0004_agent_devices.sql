-- Persist the user's Orialis Agent devices and the device selected for routing.
-- Connection liveness remains in memory; last_seen_at is only a durable hint.
CREATE TABLE agent_devices (
    device_id TEXT NOT NULL PRIMARY KEY,
    user_id TEXT NOT NULL,
    client TEXT NOT NULL,
    plugin_version TEXT NOT NULL,
    platform TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE INDEX idx_agent_devices_user_updated
    ON agent_devices (user_id, updated_at, device_id);

CREATE TABLE agent_preferences (
    user_id TEXT NOT NULL PRIMARY KEY,
    active_device_id TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    version INTEGER NOT NULL DEFAULT 1 CHECK (version > 0),
    FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
    FOREIGN KEY (active_device_id) REFERENCES agent_devices (device_id) ON DELETE SET NULL
);
