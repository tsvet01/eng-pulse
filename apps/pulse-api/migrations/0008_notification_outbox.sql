CREATE TABLE notification_outbox (
  feed_id          uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date             date NOT NULL,
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel          text NOT NULL CHECK (channel IN ('email','push')),
  state            text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','sent','failed','skipped')),
  attempts         integer NOT NULL DEFAULT 0,
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  lease_expires_at timestamptz,
  last_error       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, date, user_id, channel)
);
CREATE INDEX notification_outbox_due ON notification_outbox (next_attempt_at) WHERE state = 'pending';
ALTER TABLE device_tokens ADD COLUMN environment text NOT NULL DEFAULT 'production'
  CHECK (environment IN ('sandbox','production'));
