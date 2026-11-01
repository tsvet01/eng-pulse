CREATE TABLE articles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    canonical_url text UNIQUE NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE article_briefs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    article_id uuid NOT NULL REFERENCES articles(id),
    fingerprint bytea NOT NULL,
    format text NOT NULL,
    payload jsonb NOT NULL,
    article_url text NOT NULL,
    article_title text NOT NULL,
    model text,
    eval_score double precision,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (article_id, fingerprint)
);

CREATE TABLE legacy_brief_identity (
    feed_id uuid NOT NULL,
    date date NOT NULL,
    brief_id uuid NOT NULL REFERENCES article_briefs(id),
    original_brief_id uuid NOT NULL REFERENCES article_briefs(id),
    PRIMARY KEY (feed_id, date),
    FOREIGN KEY (feed_id, date) REFERENCES briefs(feed_id, date) ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE FUNCTION preserve_brief_identity() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    article uuid;
    version uuid;
    signature bytea;
BEGIN
    -- Conservative identity: preserve query strings, case and fragments. They can identify different content.
    INSERT INTO articles(canonical_url) VALUES (btrim(NEW.article_url)) ON CONFLICT DO NOTHING;
    SELECT id INTO STRICT article FROM articles WHERE canonical_url = btrim(NEW.article_url);
    signature := digest(jsonb_build_array(NEW.format, NEW.payload, NEW.article_url,
        NEW.article_title, NEW.model, NEW.eval_score)::text, 'sha256');
    INSERT INTO article_briefs(article_id, fingerprint, format, payload, article_url, article_title, model, eval_score)
        VALUES (article, signature, NEW.format, NEW.payload, NEW.article_url, NEW.article_title, NEW.model, NEW.eval_score)
        ON CONFLICT DO NOTHING;
    SELECT id INTO STRICT version FROM article_briefs WHERE article_id = article AND fingerprint = signature;
    INSERT INTO legacy_brief_identity(feed_id, date, brief_id, original_brief_id)
        VALUES (NEW.feed_id, NEW.date, version, version)
        ON CONFLICT (feed_id, date) DO UPDATE SET brief_id = excluded.brief_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER preserve_brief_identity AFTER INSERT OR UPDATE ON briefs
    FOR EACH ROW EXECUTE FUNCTION preserve_brief_identity();

-- Backfill through the same path as imports/publications; identical replay retains both IDs.
UPDATE briefs SET payload = payload;

CREATE FUNCTION reject_brief_revision_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'article brief versions are immutable';
END;
$$;
CREATE TRIGGER immutable_article_brief BEFORE UPDATE ON article_briefs
    FOR EACH ROW EXECUTE FUNCTION reject_brief_revision_update();

CREATE TABLE user_preferences (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    preferences jsonb NOT NULL CHECK (jsonb_typeof(preferences) = 'object'),
    revision bigint NOT NULL CHECK (revision > 0),
    learned_reset_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now()
);
