use crate::{
    auth::extractors::AuthUser,
    db::{briefs, feedback, feeds},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode},
    routing::{delete, get},
    Json, Router,
};
use chrono::NaiveDate;
use pulse_core::Brief;
use serde::Deserialize;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/feeds/{id}/briefs", get(list))
        .route("/v1/briefs/{slug}/{date}", get(get_one))
        .route(
            "/v1/briefs/{slug}/{date}/feedback",
            get(get_feedback).put(put_feedback),
        )
        .route(
            "/v1/briefs/{slug}/{date}/feedback/{aspect}",
            delete(delete_feedback),
        )
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
    Ok(Json(Brief {
        feed_slug: slug,
        date: row.date.to_string(),
        format: row.format,
        payload: row.payload,
        article_url: row.article_url,
        article_title: row.article_title,
        model: row.model,
        eval_score: row.eval_score,
    }))
}

#[derive(Deserialize)]
struct FeedbackBody {
    aspect: String,
    value: i16,
}

fn expected_revision(headers: &HeaderMap, required: bool) -> Result<Option<i64>, ApiError> {
    let mut values = headers.get_all("x-expected-revision").iter();
    let Some(value) = values.next() else {
        return if required {
            Err(ApiError::BadRequest(
                "X-Expected-Revision is required".into(),
            ))
        } else {
            Ok(None)
        };
    };
    let value = value
        .to_str()
        .ok()
        .filter(|v| !v.is_empty() && v.bytes().all(|c| c.is_ascii_digit()));
    if values.next().is_some() {
        return Err(ApiError::BadRequest("invalid feedback revision".into()));
    }
    value
        .and_then(|v| v.parse().ok())
        .map(Some)
        .ok_or_else(|| ApiError::BadRequest("invalid feedback revision".into()))
}

async fn feedback_target(
    s: &AppState,
    user: &AuthUser,
    slug: &str,
    date: &str,
) -> Result<(Uuid, NaiveDate), ApiError> {
    let feed_id = briefs::feed_id_by_slug(&s.pool, slug)
        .await?
        .ok_or(ApiError::NotFound("feed"))?;
    member_feed(s, user, feed_id).await?;
    let date = parse_date(date)?;
    briefs::get(&s.pool, feed_id, date)
        .await?
        .ok_or(ApiError::NotFound("brief"))?;
    Ok((feed_id, date))
}

fn mutation_response(revision: Option<i64>) -> Result<(StatusCode, HeaderMap), ApiError> {
    let revision = revision.ok_or(ApiError::FeedbackConflict)?;
    let mut headers = HeaderMap::new();
    headers.insert("x-feedback-revision", HeaderValue::from(revision));
    Ok((StatusCode::NO_CONTENT, headers))
}

async fn get_feedback(
    State(s): State<AppState>,
    user: AuthUser,
    Path((slug, date)): Path<(String, String)>,
) -> Result<Json<feedback::PersonalFeedback>, ApiError> {
    let (feed_id, date) = feedback_target(&s, &user, &slug, &date).await?;
    Ok(Json(feedback::get(&s.pool, user.id, feed_id, date).await?))
}

async fn put_feedback(
    State(s): State<AppState>,
    user: AuthUser,
    Path((slug, date)): Path<(String, String)>,
    headers: HeaderMap,
    Json(b): Json<FeedbackBody>,
) -> Result<(StatusCode, HeaderMap), ApiError> {
    if !matches!(b.aspect.as_str(), "brief" | "selection") || !matches!(b.value, -1 | 1) {
        return Err(ApiError::BadRequest(
            "aspect must be brief|selection and value -1|1".into(),
        ));
    }
    let expected = expected_revision(&headers, false)?;
    let (feed_id, date) = feedback_target(&s, &user, &slug, &date).await?;
    mutation_response(
        feedback::write(
            &s.pool,
            user.id,
            feed_id,
            date,
            &b.aspect,
            Some(b.value),
            expected,
        )
        .await?,
    )
}

async fn delete_feedback(
    State(s): State<AppState>,
    user: AuthUser,
    Path((slug, date, aspect)): Path<(String, String, String)>,
    headers: HeaderMap,
) -> Result<(StatusCode, HeaderMap), ApiError> {
    if !matches!(aspect.as_str(), "brief" | "selection") {
        return Err(ApiError::BadRequest(
            "aspect must be brief|selection".into(),
        ));
    }
    let expected = expected_revision(&headers, true)?;
    let (feed_id, date) = feedback_target(&s, &user, &slug, &date).await?;
    mutation_response(
        feedback::write(&s.pool, user.id, feed_id, date, &aspect, None, expected).await?,
    )
}
