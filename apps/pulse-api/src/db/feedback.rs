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
pub struct PersonalFeedback {
    pub selection: Option<i16>,
    pub brief: Option<i16>,
}

pub async fn for_user(
    pool: &PgPool,
    user: Uuid,
    feed: Uuid,
    date: NaiveDate,
) -> sqlx::Result<PersonalFeedback> {
    let rows: Vec<(String, i16)> = sqlx::query_as(
        "select aspect, value from feedback where user_id = $1 and feed_id = $2 and date = $3",
    )
    .bind(user)
    .bind(feed)
    .bind(date)
    .fetch_all(pool)
    .await?;
    let mut result = PersonalFeedback::default();
    for (aspect, value) in rows {
        match aspect.as_str() {
            "selection" => result.selection = Some(value),
            "brief" => result.brief = Some(value),
            _ => {}
        }
    }
    Ok(result)
}

pub async fn delete(
    pool: &PgPool,
    user: Uuid,
    feed: Uuid,
    date: NaiveDate,
    aspect: &str,
) -> sqlx::Result<()> {
    sqlx::query(
        "delete from feedback where user_id = $1 and feed_id = $2 and date = $3 and aspect = $4",
    )
    .bind(user)
    .bind(feed)
    .bind(date)
    .bind(aspect)
    .execute(pool)
    .await
    .map(|_| ())
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
