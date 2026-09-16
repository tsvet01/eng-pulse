use crate::{
    auth::extractors::AuthUser,
    db::{briefs, feedback, feeds},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, put},
    Json, Router,
};
use chrono::NaiveDate;
use pulse_core::{Brief, InsightBrief};
use serde::Deserialize;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/feeds/{id}/briefs", get(list))
        .route("/v1/briefs/{slug}/{date}", get(get_one))
        .route("/v1/briefs/{slug}/{date}/feedback", put(put_feedback))
}

#[derive(Deserialize)]
struct ListQuery {
    before: Option<String>,
    limit: Option<i64>,
}

fn parse_date(s: &str) -> Result<NaiveDate, ApiError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .map_err(|_| ApiError::BadRequest(format!("bad date: {s}")))
}

async fn member_feed(s: &AppState, user: &AuthUser, feed_id: Uuid) -> Result<(), ApiError> {
    if !feeds::exists(&s.pool, feed_id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    if feeds::is_member(&s.pool, user.id, feed_id).await? {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

async fn list(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Query(q): Query<ListQuery>,
) -> Result<Json<Vec<briefs::BriefSummary>>, ApiError> {
    member_feed(&s, &user, id).await?;
    let before = q.before.as_deref().map(parse_date).transpose()?;
    Ok(Json(
        briefs::list(&s.pool, id, before, q.limit.unwrap_or(30).clamp(1, 100)).await?,
    ))
}

async fn get_one(
    State(s): State<AppState>,
    user: AuthUser,
    Path((slug, date)): Path<(String, String)>,
) -> Result<Json<Brief>, ApiError> {
    let feed_id = briefs::feed_id_by_slug(&s.pool, &slug)
        .await?
        .ok_or(ApiError::NotFound("feed"))?;
    member_feed(&s, &user, feed_id).await?;
    let row = briefs::get(&s.pool, feed_id, parse_date(&date)?)
        .await?
        .ok_or(ApiError::NotFound("brief"))?;
    let payload: InsightBrief = serde_json::from_value(row.payload)
        .map_err(|e| ApiError::Internal(format!("stored payload: {e}")))?;
    Ok(Json(Brief {
        feed_slug: slug,
        date: row.date.to_string(),
        format: row.format,
        payload,
        article_url: row.article_url,
        article_title: row.article_title,
        model: row.model,
        eval_score: row.eval_score.map(f64::from),
    }))
}

#[derive(Deserialize)]
struct FeedbackBody {
    aspect: String,
    value: i16,
}

async fn put_feedback(
    State(s): State<AppState>,
    user: AuthUser,
    Path((slug, date)): Path<(String, String)>,
    Json(b): Json<FeedbackBody>,
) -> Result<StatusCode, ApiError> {
    if !matches!(b.aspect.as_str(), "brief" | "selection") || !matches!(b.value, -1 | 1) {
        return Err(ApiError::BadRequest(
            "aspect must be brief|selection and value -1|1".into(),
        ));
    }
    let feed_id = briefs::feed_id_by_slug(&s.pool, &slug)
        .await?
        .ok_or(ApiError::NotFound("feed"))?;
    member_feed(&s, &user, feed_id).await?;
    feedback::upsert(
        &s.pool,
        user.id,
        feed_id,
        parse_date(&date)?,
        &b.aspect,
        b.value,
    )
    .await?;
    Ok(StatusCode::NO_CONTENT)
}
