-- Additive upgrade: null keeps the default order; quotes survive source deletion.
ALTER TABLE tasks ADD COLUMN manual_position INTEGER;
ALTER TABLE projects ADD COLUMN manual_position INTEGER;
ALTER TABLE conversations ADD COLUMN manual_position INTEGER;
ALTER TABLE conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT;
ALTER TABLE messages ADD COLUMN reply_quote TEXT;
ALTER TABLE messages ADD COLUMN reply_role TEXT;
