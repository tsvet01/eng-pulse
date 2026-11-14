pub mod message;

use crate::db::{briefs, outbox};
use chrono::{DateTime, Duration, NaiveDate, Utc};
use sqlx::PgPool;
use std::{future::Future, pin::Pin, task::Poll};
use tracing::{error, warn};

pub const MAX_ATTEMPTS: i32 = 5;
const BATCH: i64 = 20;
const STALE_AFTER: Duration = Duration::hours(12);
const SEND_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(20);
const TICK: std::time::Duration = std::time::Duration::from_secs(30);

pub struct Message {
    pub title: String,
    pub body: String,
    pub feed_slug: String,
    pub date: NaiveDate,
}

#[derive(Debug)]
pub enum SendError {
    Transient(String),
    Permanent(String),
    InvalidToken,
}

pub trait Deliver: Send + Sync {
    fn push(
        &self,
        token: &str,
        sandbox: bool,
        m: &Message,
    ) -> impl Future<Output = Result<(), SendError>> + Send;
}

pub fn backoff(attempts: i32) -> Duration {
    Duration::minutes(match attempts {
        ..=1 => 1,
        2 => 5,
        3 => 15,
        _ => 60,
    })
}

pub async fn run(pool: PgPool, d: impl Deliver) -> Result<(), String> {
    let mut tick = tokio::time::interval(TICK);
    loop {
        tick.tick().await;
        if let Err(e) = run_once(&pool, &d, Utc::now()).await {
            error!(error = %e, "notification batch failed");
        }
    }
}

pub async fn run_once(
    pool: &PgPool,
    d: &impl Deliver,
    now: DateTime<Utc>,
) -> Result<usize, String> {
    let rows = outbox::lease(pool, now, BATCH)
        .await
        .map_err(|e| e.to_string())?;
    for l in &rows {
        if let Err(e) = process(pool, d, now, l).await {
            error!(user_id = %l.user_id, error = %e, "notification row failed");
        }
    }
    Ok(rows.len())
}

async fn process(
    pool: &PgPool,
    d: &impl Deliver,
    now: DateTime<Utc>,
    l: &outbox::Leased,
) -> sqlx::Result<()> {
    if now - l.created_at > STALE_AFTER {
        return outbox::mark_skipped(pool, l, "expired", now).await;
    }
    let tokens = match outbox::tokens(pool, l).await? {
        Ok(t) => t,
        Err(reason) => return outbox::mark_skipped(pool, l, reason, now).await,
    };
    let Some(brief) = briefs::get(pool, l.feed_id, l.date).await? else {
        return outbox::mark_skipped(pool, l, "no_brief", now).await;
    };
    let slug: Option<String> = sqlx::query_scalar(
        "select slug from feeds where id=$1 and is_active and slug='engineering'",
    )
    .bind(l.feed_id)
    .fetch_optional(pool)
    .await?;
    let Some(slug) = slug else {
        return outbox::mark_skipped(pool, l, "feed_inactive", now).await;
    };
    let msg = message::build(&brief, &slug);

    let sends = tokens.iter().map(|(token, sandbox)| {
        let msg = &msg;
        Box::pin(async move {
            match tokio::time::timeout(SEND_TIMEOUT, d.push(token, *sandbox, msg)).await {
                Ok(r) => r,
                Err(_) => Err(SendError::Transient("send timed out".into())),
            }
        }) as Pin<Box<dyn Future<Output = Result<(), SendError>> + Send + '_>>
    });
    let results = join_all(sends.collect()).await;

    let (mut accepted, mut transient, mut permanent) = (false, None, None);
    for ((token, _), r) in tokens.iter().zip(results) {
        match r {
            Ok(()) => accepted = true,
            Err(SendError::InvalidToken) => {
                outbox::deactivate_token(pool, l.user_id, token, now).await?
            }
            Err(SendError::Transient(e)) => transient = Some(scrub(&e, token)),
            Err(SendError::Permanent(e)) => permanent = Some(scrub(&e, token)),
        }
    }
    if accepted {
        outbox::mark_sent(pool, l, now).await
    } else if let Some(e) = transient {
        if l.attempts >= MAX_ATTEMPTS {
            outbox::mark_failed(pool, l, &e, now).await
        } else {
            warn!(attempts = l.attempts, "push will be retried");
            outbox::mark_retry(pool, l, &e, now).await
        }
    } else if let Some(e) = permanent {
        outbox::mark_failed(pool, l, &e, now).await
    } else {
        outbox::mark_skipped(pool, l, "no_device", now).await
    }
}

fn scrub(e: &str, token: &str) -> String {
    e.replace(token, "[token]").chars().take(200).collect()
}

async fn join_all<'a, T>(mut fs: Vec<Pin<Box<dyn Future<Output = T> + Send + 'a>>>) -> Vec<T> {
    let mut out: Vec<Option<T>> = fs.iter().map(|_| None).collect();
    std::future::poll_fn(|cx| {
        let mut pending = false;
        for (f, o) in fs.iter_mut().zip(out.iter_mut()) {
            if o.is_none() {
                match f.as_mut().poll(cx) {
                    Poll::Ready(v) => *o = Some(v),
                    Poll::Pending => pending = true,
                }
            }
        }
        if pending {
            Poll::Pending
        } else {
            Poll::Ready(())
        }
    })
    .await;
    out.into_iter().flatten().collect()
}
