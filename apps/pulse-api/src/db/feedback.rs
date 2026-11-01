use chrono::NaiveDate;
use sqlx::{Executor, PgPool, Postgres};
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct FeedbackRow {
    pub user_id: Uuid,
    pub date: NaiveDate,
    pub aspect: String,
    pub value: i16,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct FeedbackValue {
    pub value: Option<i16>,
    pub revision: i64,
}

#[derive(Debug, Default, serde::Serialize)]
pub struct PersonalFeedback {
    pub selection: FeedbackValue,
    pub brief: FeedbackValue,
}

pub struct Target<'a> {
    pub article_id: Uuid,
    pub aspect: &'a str,
    pub brief_id: Option<Uuid>,
}

#[derive(Debug, Default, sqlx::FromRow, serde::Serialize)]
pub struct StableFeedback {
    pub value: Option<i16>,
    pub reason: Option<String>,
    pub revision: i64,
}

pub async fn get_stable(
    pool: &PgPool,
    user: Uuid,
    target: &Target<'_>,
) -> sqlx::Result<StableFeedback> {
    Ok(sqlx::query_as(
        "select value,reason,revision from article_feedback
        where user_id=$1 and article_id=$2 and aspect=$3 and brief_id is not distinct from $4",
    )
    .bind(user)
    .bind(target.article_id)
    .bind(target.aspect)
    .bind(target.brief_id)
    .fetch_optional(pool)
    .await?
    .unwrap_or_default())
}

pub async fn get(
    pool: &PgPool,
    user_id: Uuid,
    feed_id: Uuid,
    date: NaiveDate,
) -> sqlx::Result<PersonalFeedback> {
    let rows: Vec<(String, Option<i16>, i64)> = sqlx::query_as(
        "select f.aspect,f.value,f.revision from legacy_brief_identity l
        join article_briefs b on b.id=l.brief_id
        join article_feedback f on f.article_id=b.article_id and f.user_id=$1
            and (f.aspect='relevance' or (f.aspect='brief_quality' and f.brief_id=b.id))
        where l.feed_id=$2 and l.date=$3",
    )
    .bind(user_id)
    .bind(feed_id)
    .bind(date)
    .fetch_all(pool)
    .await?;
    let mut feedback = PersonalFeedback::default();
    for (aspect, value, revision) in rows {
        let target = match aspect.as_str() {
            "relevance" => &mut feedback.selection,
            "brief_quality" => &mut feedback.brief,
            _ => continue,
        };
        *target = FeedbackValue { value, revision };
    }
    Ok(feedback)
}

/// None means the expected revision lost a race or no longer matches.
pub async fn write<'e>(
    executor: impl Executor<'e, Database = Postgres>,
    user: Uuid,
    target: &Target<'_>,
    value: Option<i16>,
    reason: Option<&str>,
    expected: Option<i64>,
) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar(
        "insert into article_feedback (user_id,article_id,aspect,brief_id,value,reason)
        select $1,$2,$3,$4,$5,$6
        where $7::bigint is null or $7=0 or exists (
            select 1 from article_feedback where user_id=$1 and article_id=$2
                and aspect=$3 and brief_id is not distinct from $4
        )
        on conflict (user_id,article_id,aspect,brief_id) do update
        set value=excluded.value, reason=excluded.reason,
            revision=article_feedback.revision + case when article_feedback.value is null and excluded.value is null then 0 else 1 end,
            created_at=case when article_feedback.value is null and excluded.value is null then article_feedback.created_at else now() end
        where $7::bigint is null or article_feedback.revision=$7
        returning revision",
    )
    .bind(user).bind(target.article_id).bind(target.aspect).bind(target.brief_id)
    .bind(value).bind(reason).bind(expected).fetch_optional(executor).await
}

/// Legacy export projects only votes about each date's current content.
pub async fn list_since(
    pool: &PgPool,
    feed_id: Uuid,
    since: NaiveDate,
) -> sqlx::Result<Vec<FeedbackRow>> {
    sqlx::query_as(
        "select f.user_id,l.date,case f.aspect when 'relevance' then 'selection' else 'brief' end as aspect,f.value
        from legacy_brief_identity l join article_briefs b on b.id=l.brief_id
        join article_feedback f on f.article_id=b.article_id
            and (f.aspect='relevance' or (f.aspect='brief_quality' and f.brief_id=b.id))
        where l.feed_id=$1 and l.date >= $2 and f.value is not null
        order by l.date desc,f.user_id,f.aspect",
    )
    .bind(feed_id).bind(since).fetch_all(pool).await
}
