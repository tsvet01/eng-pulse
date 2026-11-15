-- A reservation survives crashes and account removal. Never reclaim it for another attempt.
CREATE TABLE pilot_push_test_attempts (
  test_id uuid PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  outcome text NOT NULL DEFAULT 'reserved' CHECK (outcome IN ('reserved','accepted','not_confirmed'))
);
