CREATE TABLE reconciliation_state (
    id smallint PRIMARY KEY CHECK (id = 1),
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    last_success_at timestamptz,
    outcome text NOT NULL CHECK (outcome IN ('running', 'ok', 'error')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 3),
    consecutive_failures integer NOT NULL DEFAULT 0,
    last_error text,
    latest_source_date date,
    report jsonb
);
