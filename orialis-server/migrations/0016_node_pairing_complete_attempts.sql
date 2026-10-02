ALTER TABLE node_pairings
    ADD COLUMN complete_attempts INTEGER NOT NULL DEFAULT 0 CHECK (complete_attempts >= 0);
