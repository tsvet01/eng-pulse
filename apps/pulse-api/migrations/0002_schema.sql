CREATE TABLE users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email        citext UNIQUE NOT NULL,
  display_name text,
  is_admin     boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE identities (
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issuer   text NOT NULL,
  subject  text NOT NULL,
  PRIMARY KEY (issuer, subject)
);
CREATE INDEX identities_user_idx ON identities(user_id);
CREATE TABLE invites (
  code        text PRIMARY KEY,
  created_by  uuid REFERENCES users(id),
  max_uses    integer NOT NULL DEFAULT 1,
  used_count  integer NOT NULL DEFAULT 0,
  expires_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE feeds (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  description text,
  created_by  uuid REFERENCES users(id),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE feed_topics (
  feed_id    uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  topic      text NOT NULL,
  added_by   uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, topic)
);
CREATE TABLE feed_sources (
  feed_id    uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  url        text NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('rss','atom','hackernews')),
  added_by   uuid REFERENCES users(id),
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, url)
);
CREATE TABLE memberships (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  feed_id      uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  role         text NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
  notify_email boolean NOT NULL DEFAULT true,
  notify_push  boolean NOT NULL DEFAULT true,
  joined_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, feed_id)
);
CREATE TABLE briefs (
  feed_id       uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date          date NOT NULL,
  format        text NOT NULL,
  payload       jsonb NOT NULL,
  article_url   text NOT NULL,
  article_title text NOT NULL,
  model         text,
  eval_score    real,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, date)
);
CREATE TABLE feedback (
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  feed_id    uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date       date NOT NULL,
  aspect     text NOT NULL,
  value      smallint NOT NULL CHECK (value IN (-1, 1)),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, feed_id, date, aspect)
);
CREATE TABLE device_tokens (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform    text NOT NULL CHECK (platform IN ('ios','android')),
  token       text UNIQUE NOT NULL,
  app_version text,
  is_active   boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE notifications_sent (
  feed_id  uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date     date NOT NULL,
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel  text NOT NULL,
  sent_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, date, user_id, channel)
);
CREATE TABLE runs (
  date          date NOT NULL,
  feed_id       uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  status        text NOT NULL CHECK (status IN ('ok','skipped','failed')),
  article_url   text,
  input_tokens  bigint NOT NULL DEFAULT 0,
  output_tokens bigint NOT NULL DEFAULT 0,
  est_cost_usd  double precision NOT NULL DEFAULT 0,
  error         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (date, feed_id)
);
