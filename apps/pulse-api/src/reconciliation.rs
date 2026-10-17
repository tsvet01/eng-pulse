//! Repair missed publications from the public archive without generating content.
use crate::{
    history::{self, PublicArchive},
    state::AppState,
};
use axum::{extract::State, http::StatusCode, Json};
use chrono::{DateTime, NaiveDate, Timelike, Utc};
use serde::Serialize;
use serde_json::Value;
use sqlx::PgPool;
use std::{future::Future, time::Duration};

pub const LOCK_ID: i64 = 82374612;
const INTERVAL: Duration = Duration::from_secs(15 * 60);
const RETRY_DELAY: Duration = Duration::from_secs(30);
const CYCLE_LIMIT: Duration = Duration::from_secs(11 * 60);
const MAX_ATTEMPTS: i32 = 3;

#[derive(Debug, PartialEq)]
pub enum CycleOutcome {
    Succeeded,
    Failed,
    Skipped,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct Snapshot {
    pub started_at: DateTime<Utc>,
    pub finished_at: Option<DateTime<Utc>>,
    pub last_success_at: Option<DateTime<Utc>>,
    pub outcome: String,
    pub attempts: i32,
    pub consecutive_failures: i32,
    pub last_error: Option<String>,
    pub latest_source_date: Option<NaiveDate>,
    pub report: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct Freshness {
    pub status: &'static str,
    pub reason: &'static str,
}
impl Freshness {
    fn degraded(reason: &'static str) -> Self {
        Self {
            status: "degraded",
            reason,
        }
    }
}

async fn db<T>(operation: impl Future<Output = Result<T, sqlx::Error>>) -> Result<T, String> {
    tokio::time::timeout(Duration::from_secs(15), operation)
        .await
        .map_err(|_| "reconciliation database operation timed out")?
        .map_err(|_| "reconciliation database operation failed".into())
}

pub async fn status(pool: &PgPool) -> Result<Option<Snapshot>, String> {
    db(sqlx::query_as("select started_at,finished_at,last_success_at,outcome,attempts,consecutive_failures,last_error,latest_source_date,report from reconciliation_state where id=1")
        .fetch_optional(pool)).await
}

pub async fn probe(pool: &PgPool, enabled: bool, now: DateTime<Utc>) -> Result<Freshness, String> {
    if !enabled {
        return Ok(Freshness::degraded("disabled"));
    }
    let Some(snapshot) = status(pool).await? else {
        return Ok(Freshness::degraded("uninitialized"));
    };
    let Some(success) = snapshot.last_success_at else {
        return Ok(Freshness::degraded("uninitialized"));
    };
    if success < now - chrono::Duration::minutes(45) || success > now + chrono::Duration::minutes(1)
    {
        return Ok(Freshness::degraded("checkpoint_stale"));
    }
    let expected = if now.hour() < 7 || (now.hour() == 7 && now.minute() < 30) {
        now.date_naive()
            .pred_opt()
            .ok_or("invalid freshness date")?
    } else {
        now.date_naive()
    };
    if snapshot
        .latest_source_date
        .is_none_or(|date| date < expected)
    {
        return Ok(Freshness::degraded("source_behind"));
    }
    let latest: Option<NaiveDate> = db(sqlx::query_scalar("select max(b.date) from briefs b join feeds f on f.id=b.feed_id where f.slug='engineering' and f.is_active")
        .fetch_one(pool)).await?;
    if latest.is_none_or(|date| date < expected) {
        return Ok(Freshness::degraded("mirror_behind"));
    }
    Ok(Freshness {
        status: "ok",
        reason: "current",
    })
}

pub async fn healthz(State(state): State<AppState>) -> (StatusCode, Json<Freshness>) {
    let body = probe(&state.pool, state.cfg.reconcile_history_enabled, Utc::now())
        .await
        .unwrap_or_else(|_| Freshness::degraded("unavailable"));
    let code = if body.status == "ok" {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (code, Json(body))
}

pub async fn reconcile_cycle(
    pool: &PgPool,
    source: &PublicArchive,
    end: NaiveDate,
    retry_delay: Duration,
) -> Result<CycleOutcome, String> {
    tokio::time::timeout(CYCLE_LIMIT, cycle_inner(pool, source, end, retry_delay))
        .await
        .map_err(|_| "reconciliation cycle exceeded its eleven-minute limit".to_string())?
}

async fn cycle_inner(
    pool: &PgPool,
    source: &PublicArchive,
    end: NaiveDate,
    retry_delay: Duration,
) -> Result<CycleOutcome, String> {
    // This transaction owns only the worker lock; checkpoints commit independently.
    let mut owner = db(pool.begin()).await?;
    db(sqlx::query("set local idle_in_transaction_session_timeout = '12min'").execute(&mut *owner))
        .await?;
    let locked: bool = db(sqlx::query_scalar("select pg_try_advisory_xact_lock($1)")
        .bind(LOCK_ID)
        .fetch_one(&mut *owner))
    .await?;
    if !locked {
        return Ok(CycleOutcome::Skipped);
    }
    db(sqlx::query("insert into reconciliation_state(id,started_at,outcome) values(1,clock_timestamp(),'running') on conflict(id) do update set started_at=clock_timestamp(),finished_at=null,outcome='running',attempts=0,last_error=null")
        .execute(pool)).await?;
    for attempt in 1..=MAX_ATTEMPTS {
        db(
            sqlx::query("update reconciliation_state set attempts=$1 where id=1")
                .bind(attempt)
                .execute(pool),
        )
        .await?;
        match history::import_window(pool, source, end).await {
            Ok(report) => {
                let latest = report.expected_dates.iter().max().copied();
                let json = serde_json::to_value(&report)
                    .map_err(|_| "could not encode reconciliation report")?;
                db(sqlx::query("update reconciliation_state set finished_at=clock_timestamp(),last_success_at=clock_timestamp(),outcome='ok',consecutive_failures=0,last_error=null,latest_source_date=$1,report=$2 where id=1")
                    .bind(latest).bind(json).execute(pool)).await?;
                db(owner.rollback()).await?;
                return Ok(CycleOutcome::Succeeded);
            }
            Err(error) => {
                tracing::warn!(attempt,error=%error,"History reconciliation attempt failed");
                db(
                    sqlx::query("update reconciliation_state set last_error=$1 where id=1")
                        .bind(error)
                        .execute(pool),
                )
                .await?;
                if attempt < MAX_ATTEMPTS {
                    tokio::time::sleep(retry_delay).await;
                }
            }
        }
    }
    db(sqlx::query("update reconciliation_state set finished_at=clock_timestamp(),outcome='error',consecutive_failures=consecutive_failures+1 where id=1")
        .execute(pool)).await?;
    db(owner.rollback()).await?;
    Ok(CycleOutcome::Failed)
}

pub async fn run(pool: PgPool) -> Result<(), String> {
    let source = PublicArchive::new(
        history::GCS_ROOT
            .parse()
            .map_err(|_| "invalid archive root")?,
    )?;
    let mut ticks = tokio::time::interval(INTERVAL);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        ticks.tick().await;
        match reconcile_cycle(&pool, &source, Utc::now().date_naive(), RETRY_DELAY).await {
            Ok(outcome) => tracing::info!(?outcome, "History reconciliation cycle finished"),
            Err(error) => tracing::error!(%error,"History reconciliation cycle failed"),
        }
    }
}
