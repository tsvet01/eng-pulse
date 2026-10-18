use chrono::NaiveDate;
use sqlx::PgPool;
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

pub async fn get(
    pool: &PgPool,
    user_id: Uuid,
    feed_id: Uuid,
    date: NaiveDate,
) -> sqlx::Result<PersonalFeedback> {
    let rows: Vec<(String, Option<i16>, i64)> = sqlx::query_as(
        "select aspect, value, revision from feedback where user_id = $1 and feed_id = $2 and date = $3",
    )
    .bind(user_id).bind(feed_id).bind(date).fetch_all(pool).await?;
    let mut feedback = PersonalFeedback::default();
    for (aspect, value, revision) in rows {
        let target = match aspect.as_str() {
            "selection" => &mut feedback.selection,
            "brief" => &mut feedback.brief,
            _ => continue,
        };
        *target = FeedbackValue { value, revision };
    }
    Ok(feedback)
}

/// None means the expected revision lost a race or no longer matches.
pub async fn write(
    pool: &PgPool,
    user_id: Uuid,
    feed_id: Uuid,
    date: NaiveDate,
    aspect: &str,
    value: Option<i16>,
    expected: Option<i64>,
) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar(
        "insert into feedback (user_id, feed_id, date, aspect, value)
         select $1, $2, $3, $4, $5
         where $6::bigint is null or $6 = 0 or exists (
             select 1 from feedback where user_id = $1 and feed_id = $2 and date = $3 and aspect = $4
         )
         on conflict (user_id, feed_id, date, aspect) do update
         set value = excluded.value,
             revision = feedback.revision + case when feedback.value is null and excluded.value is null then 0 else 1 end,
             created_at = case when feedback.value is null and excluded.value is null then feedback.created_at else now() end
         where $6::bigint is null or feedback.revision = $6
         returning revision",
    )
    .bind(user_id).bind(feed_id).bind(date).bind(aspect).bind(value).bind(expected)
    .fetch_optional(pool).await
}

pub async fn list_since(
    pool: &PgPool,
    feed_id: Uuid,
    since: NaiveDate,
) -> sqlx::Result<Vec<FeedbackRow>> {
    sqlx::query_as("select user_id, date, aspect, value from feedback where feed_id = $1 and date >= $2 and value is not null order by date desc")
        .bind(feed_id).bind(since).fetch_all(pool).await
}
