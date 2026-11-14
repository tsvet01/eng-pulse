use chrono::{DateTime, NaiveDate, Utc};
use sqlx::{PgPool, Postgres, Transaction};
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

#[derive(Debug, sqlx::FromRow)]
pub struct Leased {
    pub feed_id: Uuid,
    pub date: NaiveDate,
    pub user_id: Uuid,
    pub attempts: i32,
    pub created_at: DateTime<Utc>,
}

/// Claims due pushes for 2 minutes; a crashed worker's rows become due again.
pub async fn lease(pool: &PgPool, now: DateTime<Utc>, limit: i64) -> sqlx::Result<Vec<Leased>> {
    sqlx::query_as("update notification_outbox set lease_expires_at=$1 + interval '2 minutes', attempts=attempts+1, updated_at=$1 where (feed_id,date,user_id,channel) in (select feed_id,date,user_id,channel from notification_outbox where state='pending' and channel='push' and next_attempt_at<=$1 and (lease_expires_at is null or lease_expires_at<$1) order by next_attempt_at limit $2 for update skip locked) returning feed_id,date,user_id,attempts,created_at")
        .bind(now).bind(limit).fetch_all(pool).await
}

/// Active iOS tokens as (token, is_sandbox), or the reason the account no longer qualifies.
pub async fn tokens(
    pool: &PgPool,
    l: &Leased,
) -> sqlx::Result<Result<Vec<(String, bool)>, &'static str>> {
    let active: Option<bool> = sqlx::query_scalar("select is_active from users where id=$1")
        .bind(l.user_id)
        .fetch_optional(pool)
        .await?;
    if active != Some(true) {
        return Ok(Err("user_inactive"));
    }
    let push: Option<bool> =
        sqlx::query_scalar("select notify_push from memberships where user_id=$1 and feed_id=$2")
            .bind(l.user_id)
            .bind(l.feed_id)
            .fetch_optional(pool)
            .await?;
    match push {
        None => return Ok(Err("not_member")),
        Some(false) => return Ok(Err("preference_off")),
        Some(true) => {}
    }
    let tokens: Vec<(String, bool)> = sqlx::query_as("select token, environment='sandbox' from device_tokens where user_id=$1 and platform='ios' and is_active order by token")
        .bind(l.user_id).fetch_all(pool).await?;
    Ok(if tokens.is_empty() {
        Err("no_device")
    } else {
        Ok(tokens)
    })
}

pub async fn deactivate_token(pool: &PgPool, user_id: Uuid, token: &str) -> sqlx::Result<()> {
    sqlx::query(
        "update device_tokens set is_active=false, updated_at=now() where user_id=$1 and token=$2",
    )
    .bind(user_id)
    .bind(token)
    .execute(pool)
    .await
    .map(|_| ())
}

/// Records provider acceptance and closes the row atomically.
pub async fn mark_sent(pool: &PgPool, l: &Leased, now: DateTime<Utc>) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query("insert into notifications_sent (feed_id,date,user_id,channel,sent_at) values ($1,$2,$3,'push',$4) on conflict do nothing")
        .bind(l.feed_id).bind(l.date).bind(l.user_id).bind(now).execute(&mut *tx).await?;
    close(&mut tx, l, "sent", None, now).await?;
    tx.commit().await
}

pub async fn mark_skipped(
    pool: &PgPool,
    l: &Leased,
    reason: &str,
    now: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    close(&mut tx, l, "skipped", Some(reason), now).await?;
    tx.commit().await
}

pub async fn mark_failed(
    pool: &PgPool,
    l: &Leased,
    error: &str,
    now: DateTime<Utc>,
) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    close(&mut tx, l, "failed", Some(error), now).await?;
    tx.commit().await
}

pub async fn mark_retry(
    pool: &PgPool,
    l: &Leased,
    error: &str,
    now: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query("update notification_outbox set lease_expires_at=null, last_error=$5, next_attempt_at=$6, updated_at=$7 where feed_id=$1 and date=$2 and user_id=$3 and channel='push' and state='pending' and attempts=$4")
        .bind(l.feed_id).bind(l.date).bind(l.user_id).bind(l.attempts).bind(error)
        .bind(now + crate::notify::backoff(l.attempts)).bind(now)
        .execute(pool).await.map(|_| ())
}

async fn close(
    tx: &mut Transaction<'_, Postgres>,
    l: &Leased,
    state: &str,
    error: Option<&str>,
    now: DateTime<Utc>,
) -> sqlx::Result<()> {
    sqlx::query("update notification_outbox set state=$4, last_error=$5, lease_expires_at=null, updated_at=$6 where feed_id=$1 and date=$2 and user_id=$3 and channel='push'")
        .bind(l.feed_id).bind(l.date).bind(l.user_id).bind(state).bind(error).bind(now)
        .execute(&mut **tx).await.map(|_| ())
}
