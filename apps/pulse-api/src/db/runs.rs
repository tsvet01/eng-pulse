use chrono::NaiveDate;
use pulse_core::{FeedRun, RunStatus};
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

fn status_str(s: RunStatus) -> &'static str {
    match s {
        RunStatus::Ok => "ok",
        RunStatus::Skipped => "skipped",
        RunStatus::Failed => "failed",
    }
}

/// Runs on the caller's open transaction so a batch of feeds is all-or-nothing.
pub async fn upsert(
    tx: &mut Transaction<'_, Postgres>,
    date: NaiveDate,
    feed_id: Uuid,
    r: &FeedRun,
) -> sqlx::Result<()> {
    sqlx::query("insert into runs (date, feed_id, status, article_url, input_tokens, output_tokens, est_cost_usd, error) values ($1,$2,$3,$4,$5,$6,$7,$8)
        on conflict (date, feed_id) do update set status = excluded.status, article_url = excluded.article_url, input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens, est_cost_usd = excluded.est_cost_usd, error = excluded.error")
        .bind(date).bind(feed_id).bind(status_str(r.status)).bind(&r.article_url).bind(r.input_tokens as i64).bind(r.output_tokens as i64).bind(r.est_cost_usd).bind(&r.error)
        .execute(&mut **tx).await.map(|_| ())
}
