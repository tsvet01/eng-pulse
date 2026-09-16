use chrono::NaiveDate;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
pub struct BriefRow {
    pub feed_id: Uuid,
    pub date: NaiveDate,
    pub format: String,
    pub payload: serde_json::Value,
    pub article_url: String,
    pub article_title: String,
    pub model: Option<String>,
    pub eval_score: Option<f32>,
}

/// Returns true when a new row was created.
pub async fn upsert(
    pool: &PgPool,
    feed_id: Uuid,
    date: NaiveDate,
    b: &pulse_core::Brief,
) -> sqlx::Result<bool> {
    let payload = serde_json::to_value(&b.payload).expect("brief payload serializes");
    let created: bool = sqlx::query_scalar(
        "insert into briefs (feed_id, date, format, payload, article_url, article_title, model, eval_score) values ($1,$2,$3,$4,$5,$6,$7,$8)
         on conflict (feed_id, date) do update set format = excluded.format, payload = excluded.payload, article_url = excluded.article_url, article_title = excluded.article_title, model = excluded.model, eval_score = excluded.eval_score
         returning (xmax = 0)")
        .bind(feed_id).bind(date).bind(&b.format).bind(payload).bind(&b.article_url).bind(&b.article_title).bind(&b.model).bind(b.eval_score.map(|v| v as f32))
        .fetch_one(pool).await?;
    Ok(created)
}

pub async fn get(pool: &PgPool, feed_id: Uuid, date: NaiveDate) -> sqlx::Result<Option<BriefRow>> {
    sqlx::query_as("select feed_id, date, format, payload, article_url, article_title, model, eval_score from briefs where feed_id = $1 and date = $2").bind(feed_id).bind(date).fetch_optional(pool).await
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct BriefSummary {
    pub date: NaiveDate,
    pub article_title: String,
    pub article_url: String,
    pub snippet: String,
    pub model: Option<String>,
    pub eval_score: Option<f32>,
}

pub async fn list(
    pool: &PgPool,
    feed_id: Uuid,
    before: Option<NaiveDate>,
    limit: i64,
) -> sqlx::Result<Vec<BriefSummary>> {
    sqlx::query_as("select date, article_title, article_url, left(payload->>'key_idea', 160) as snippet, model, eval_score from briefs where feed_id = $1 and ($2::date is null or date < $2) order by date desc limit $3")
        .bind(feed_id).bind(before).bind(limit).fetch_all(pool).await
}

pub async fn feed_id_by_slug(pool: &PgPool, slug: &str) -> sqlx::Result<Option<Uuid>> {
    sqlx::query_scalar("select id from feeds where slug = $1")
        .bind(slug)
        .fetch_optional(pool)
        .await
}

/// Same lookup as `feed_id_by_slug`, run on the caller's open transaction.
pub async fn feed_id_by_slug_tx(
    tx: &mut Transaction<'_, Postgres>,
    slug: &str,
) -> sqlx::Result<Option<Uuid>> {
    sqlx::query_scalar("select id from feeds where slug = $1")
        .bind(slug)
        .fetch_optional(&mut **tx)
        .await
}
