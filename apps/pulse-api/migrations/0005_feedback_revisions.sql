-- Null values retain undo revisions so stale clients cannot restore old votes.
ALTER TABLE feedback ALTER COLUMN value DROP NOT NULL;
ALTER TABLE feedback ADD COLUMN revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0);
