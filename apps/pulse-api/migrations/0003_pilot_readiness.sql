ALTER TABLE users ADD COLUMN is_active boolean NOT NULL DEFAULT true;
ALTER TABLE briefs ALTER COLUMN eval_score TYPE double precision;
