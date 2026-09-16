-- Add an optional client mutation key for idempotent sync writes.
--
-- Existing rows from 0001 receive NULL, so this migration does not require a
-- backfill and remains compatible with the original sync event history.
-- The partial unique index intentionally permits multiple NULL values while
-- enforcing one mutation_id per user when a client supplies one.

ALTER TABLE sync_events
    ADD COLUMN mutation_id TEXT;

CREATE UNIQUE INDEX uq_sync_events_user_mutation_id
    ON sync_events (user_id, mutation_id)
    WHERE mutation_id IS NOT NULL;
