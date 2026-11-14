use chrono::NaiveDate;
use sqlx::{Postgres, Transaction};
use uuid::Uuid;

/// Queues a push per opted-in active member; only for a brief dated today.
pub async fn enqueue(
    tx: &mut Transaction<'_, Postgres>,
    feed_id: Uuid,
    date: NaiveDate,
    today: NaiveDate,
    push_enabled: bool,
) -> sqlx::Result<u64> {
    if !push_enabled || date != today {
        return Ok(0);
    }
    let done = sqlx::query("insert into notification_outbox (feed_id,date,user_id,channel) select m.feed_id,$2,m.user_id,'push' from memberships m join users u on u.id=m.user_id and u.is_active where m.feed_id=$1 and m.notify_push on conflict do nothing")
        .bind(feed_id).bind(date).execute(&mut **tx).await?;
    Ok(done.rows_affected())
}
