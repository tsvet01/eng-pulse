-- Keep evidence of every publication, including intermediate immutable versions.
CREATE TABLE brief_publications (
    feed_id uuid NOT NULL,
    date date NOT NULL,
    brief_id uuid NOT NULL REFERENCES article_briefs(id),
    PRIMARY KEY (feed_id, date, brief_id),
    FOREIGN KEY (feed_id, date) REFERENCES legacy_brief_identity(feed_id, date)
        ON UPDATE CASCADE ON DELETE CASCADE
);
INSERT INTO brief_publications(feed_id, date, brief_id)
    SELECT feed_id, date, brief_id FROM legacy_brief_identity
    UNION SELECT feed_id, date, original_brief_id FROM legacy_brief_identity;

CREATE FUNCTION record_brief_publication() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    -- The key may have been deleted and reused before this deferred event runs.
    INSERT INTO brief_publications(feed_id, date, brief_id)
        SELECT feed_id, date, brief_id FROM legacy_brief_identity
        WHERE feed_id=NEW.feed_id AND date=NEW.date
        ON CONFLICT DO NOTHING;
    RETURN NEW;
END;
$$;
-- Let date-correction cascades finish before adding the new publication.
CREATE CONSTRAINT TRIGGER record_brief_publication AFTER INSERT OR UPDATE ON legacy_brief_identity
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION record_brief_publication();

ALTER TABLE article_briefs ADD CONSTRAINT article_briefs_article_id_id_key UNIQUE (article_id, id);
CREATE TABLE article_feedback (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    article_id uuid NOT NULL REFERENCES articles(id),
    aspect text NOT NULL CHECK (aspect IN ('relevance','depth','novelty','article_quality','brief_quality')),
    brief_id uuid,
    value smallint CHECK (value IN (-1,1)),
    reason text,
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE NULLS NOT DISTINCT (user_id, article_id, aspect, brief_id),
    FOREIGN KEY (article_id, brief_id) REFERENCES article_briefs(article_id, id),
    CHECK ((aspect = 'brief_quality') = (brief_id IS NOT NULL)),
    CHECK (reason IS NULL OR (value IS NOT NULL AND (
        (aspect = 'relevance' AND reason = 'more_like_this' AND value = 1) OR
        (value = -1 AND (
            (aspect = 'relevance' AND reason = 'not_relevant') OR
            (aspect = 'depth' AND reason IN ('too_basic','too_advanced')) OR
            (aspect = 'novelty' AND reason = 'already_knew_this') OR
            (aspect = 'article_quality' AND reason = 'poor_article') OR
            (aspect = 'brief_quality' AND reason IN ('inaccurate_summary','unclear_summary'))
        ))
    )))
);

-- Replays may fill missing keys but must never replace a subsequent stable vote.
CREATE FUNCTION backfill_article_feedback() RETURNS void LANGUAGE sql AS $$
    WITH mapped AS (
        SELECT f.user_id, b.article_id,
            CASE f.aspect WHEN 'selection' THEN 'relevance' ELSE 'brief_quality' END AS aspect,
            CASE WHEN f.aspect = 'brief' THEN b.id END AS brief_id,
            f.value, f.revision, f.created_at, f.date, f.feed_id
        FROM feedback f
        JOIN legacy_brief_identity l USING (feed_id, date)
        JOIN article_briefs b ON b.id = l.original_brief_id
        WHERE f.aspect IN ('selection','brief')
    ), ranked AS (
        SELECT *, row_number() OVER (
            PARTITION BY user_id, article_id, aspect, brief_id
            ORDER BY created_at DESC, date DESC, feed_id DESC
        ) AS position,
        count(*) OVER key AS sources,
        max(revision) OVER key AS max_revision
        FROM mapped WINDOW key AS (PARTITION BY user_id, article_id, aspect, brief_id)
    )
    INSERT INTO article_feedback(user_id, article_id, aspect, brief_id, value, revision, created_at)
        SELECT user_id, article_id, aspect, brief_id, value,
            CASE WHEN sources > 1 THEN max_revision + 1 ELSE revision END, created_at
        FROM ranked WHERE position = 1
        ON CONFLICT DO NOTHING;
$$;
SELECT backfill_article_feedback();
