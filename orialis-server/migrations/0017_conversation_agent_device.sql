-- Per-conversation routing takes precedence over the legacy account selection.
-- Retain the identifier if a device disappears: falling back could disclose
-- conversation content to a different execution device.
ALTER TABLE conversations ADD COLUMN agent_device_id TEXT;
