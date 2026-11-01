use sqlx::PgPool;
use uuid::Uuid;

/// The launch gate applies to historical publications as well as current ones.
pub async fn entitled(
    pool: &PgPool,
    user: Uuid,
    article: Uuid,
    brief: Option<Uuid>,
) -> sqlx::Result<bool> {
    sqlx::query_scalar(
        "select exists(select 1 from brief_publications p
        join article_briefs b on b.id=p.brief_id
        join memberships m on m.feed_id=p.feed_id and m.user_id=$1
        join feeds f on f.id=p.feed_id
        where f.is_active and f.slug='engineering' and b.article_id=$2
            and ($3::uuid is null or b.id=$3))",
    )
    .bind(user)
    .bind(article)
    .bind(brief)
    .fetch_one(pool)
    .await
}

#[derive(sqlx::FromRow)]
pub struct LegacyIdentity {
    pub article_id: Uuid,
    pub brief_id: Uuid,
    pub original_brief_id: Uuid,
}

pub async fn legacy_identity<'e>(
    executor: impl sqlx::Executor<'e, Database = sqlx::Postgres>,
    feed: Uuid,
    date: chrono::NaiveDate,
) -> sqlx::Result<Option<LegacyIdentity>> {
    // Mutations hold this mapping until their canonical write commits.
    sqlx::query_as("select b.article_id,l.brief_id,l.original_brief_id from legacy_brief_identity l join article_briefs b on b.id=l.brief_id where l.feed_id=$1 and l.date=$2 for share of l")
        .bind(feed).bind(date).fetch_optional(executor).await
}
