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

pub async fn upsert(
    pool: &PgPool,
    user_id: Uuid,
    feed_id: Uuid,
    date: NaiveDate,
    aspect: &str,
    value: i16,
) -> sqlx::Result<()> {
    sqlx::query("insert into feedback (user_id, feed_id, date, aspect, value) values ($1,$2,$3,$4,$5) on conflict (user_id, feed_id, date, aspect) do update set value = excluded.value, created_at = now()")
        .bind(user_id).bind(feed_id).bind(date).bind(aspect).bind(value).execute(pool).await.map(|_| ())
}

pub async fn list_since(
    pool: &PgPool,
    feed_id: Uuid,
    since: NaiveDate,
) -> sqlx::Result<Vec<FeedbackRow>> {
    sqlx::query_as("select user_id, date, aspect, value from feedback where feed_id = $1 and date >= $2 order by date desc")
        .bind(feed_id).bind(since).fetch_all(pool).await
}
