use crate::{
    auth::extractors::ServiceToken,
    db::{briefs, feedback, feeds, runs},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::{Query, State},
    routing::{get, post},
    Json, Router,
};
use chrono::NaiveDate;
use pulse_core::{Brief, Feed, FeedSource, RunReport, SourceKind};
use serde::Deserialize;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/internal/feeds", get(list_feeds))
        .route("/internal/briefs", post(ingest_brief))
        .route("/internal/runs", post(ingest_runs))
        .route("/internal/feedback", get(list_feedback))
}

fn parse_date(s: &str) -> Result<NaiveDate, ApiError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| ApiError::BadRequest(format!("bad date: {s}")))
}

fn kind_of(s: &str) -> SourceKind {
    match s {
        "atom" => SourceKind::Atom,
        "hackernews" => SourceKind::HackerNews,
        _ => SourceKind::Rss,
    }
}

async fn list_feeds(
    State(s): State<AppState>,
    _t: ServiceToken,
) -> Result<Json<Vec<Feed>>, ApiError> {
    let rows: Vec<(uuid::Uuid, String, String, Option<String>, bool)> = sqlx::query_as(
        "select id, slug, name, description, is_active from feeds where is_active order by slug",
    )
    .fetch_all(&s.pool)
    .await?;
    let mut out = Vec::new();
    for (id, slug, name, description, is_active) in rows {
        out.push(Feed {
            slug,
            name,
            description,
            is_active,
            topics: feeds::topics(&s.pool, id).await?,
            sources: feeds::sources(&s.pool, id)
                .await?
                .into_iter()
                .map(|r| FeedSource {
                    url: r.url,
                    kind: kind_of(&r.kind),
                })
                .collect(),
        });
    }
    Ok(Json(out))
}

async fn ingest_brief(
    State(s): State<AppState>,
    _t: ServiceToken,
    Json(b): Json<Brief>,
) -> Result<Json<Value>, ApiError> {
    let date = parse_date(&b.date)?;
    let feed_id = briefs::feed_id_by_slug(&s.pool, &b.feed_slug)
        .await?
        .ok_or(ApiError::NotFound("feed"))?;
    let created = briefs::upsert(&s.pool, feed_id, date, &b).await?;
    // Phase 1: fan-out is off; Phase 3 triggers notifications here.
    Ok(Json(
        json!({"feed_id": feed_id, "date": b.date, "created": created}),
    ))
}

async fn ingest_runs(
    State(s): State<AppState>,
    _t: ServiceToken,
    Json(r): Json<RunReport>,
) -> Result<Json<Value>, ApiError> {
    let date = parse_date(&r.date)?;
    let mut tx = s.pool.begin().await?;
    let (mut stored, mut skipped) = (0, Vec::new());
    for fr in &r.feeds {
        match briefs::feed_id_by_slug_tx(&mut tx, &fr.feed_slug).await? {
            Some(id) => {
                runs::upsert(&mut tx, date, id, fr).await?;
                stored += 1;
            }
            None => skipped.push(fr.feed_slug.clone()),
        }
    }
    tx.commit().await?;
    Ok(Json(json!({"stored": stored, "skipped": skipped})))
}

#[derive(Deserialize)]
struct FeedbackQuery {
    feed: String,
    since: String,
}

async fn list_feedback(
    State(s): State<AppState>,
    _t: ServiceToken,
    Query(q): Query<FeedbackQuery>,
) -> Result<Json<Vec<feedback::FeedbackRow>>, ApiError> {
    let feed_id = briefs::feed_id_by_slug(&s.pool, &q.feed)
        .await?
        .ok_or(ApiError::NotFound("feed"))?;
    Ok(Json(
        feedback::list_since(&s.pool, feed_id, parse_date(&q.since)?).await?,
    ))
}
