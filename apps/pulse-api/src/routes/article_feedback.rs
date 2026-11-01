use crate::{
    auth::extractors::AuthUser,
    db::{articles, feedback},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new().route(
        "/v2/articles/{article_id}/feedback/{aspect}",
        get(load).put(save).delete(undo),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FeedbackQuery {
    brief_id: Option<Uuid>,
}

async fn target<'a>(
    state: &AppState,
    user: &AuthUser,
    article_id: Uuid,
    aspect: &'a str,
    query: FeedbackQuery,
) -> Result<feedback::Target<'a>, ApiError> {
    if !matches!(
        aspect,
        "relevance" | "depth" | "novelty" | "article_quality" | "brief_quality"
    ) {
        return Err(ApiError::BadRequest("invalid feedback aspect".into()));
    }
    if (aspect == "brief_quality") != query.brief_id.is_some() {
        return Err(ApiError::BadRequest(
            "brief_id is required only for brief_quality".into(),
        ));
    }
    if !articles::entitled(&state.pool, user.id, article_id, query.brief_id).await? {
        return Err(ApiError::Forbidden);
    }
    Ok(feedback::Target {
        article_id,
        aspect,
        brief_id: query.brief_id,
    })
}

async fn load(
    State(state): State<AppState>,
    user: AuthUser,
    Path((article, aspect)): Path<(Uuid, String)>,
    Query(query): Query<FeedbackQuery>,
) -> Result<Json<feedback::StableFeedback>, ApiError> {
    let target = target(&state, &user, article, &aspect, query).await?;
    Ok(Json(
        feedback::get_stable(&state.pool, user.id, &target).await?,
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Vote {
    value: i16,
    reason: Option<String>,
}

fn valid_reason(aspect: &str, vote: &Vote) -> bool {
    let Some(reason) = vote.reason.as_deref() else {
        return true;
    };
    if reason == "more_like_this" {
        return aspect == "relevance" && vote.value == 1;
    }
    vote.value == -1
        && matches!(
            (aspect, reason),
            ("relevance", "not_relevant")
                | ("depth", "too_basic" | "too_advanced")
                | ("novelty", "already_knew_this")
                | ("article_quality", "poor_article")
                | ("brief_quality", "inaccurate_summary" | "unclear_summary")
        )
}

async fn save(
    State(state): State<AppState>,
    user: AuthUser,
    Path((article, aspect)): Path<(Uuid, String)>,
    Query(query): Query<FeedbackQuery>,
    headers: HeaderMap,
    Json(vote): Json<Vote>,
) -> Result<(StatusCode, HeaderMap), ApiError> {
    let expected = super::briefs::expected_revision(&headers, true)?;
    if !matches!(vote.value, -1 | 1) || !valid_reason(&aspect, &vote) {
        return Err(ApiError::BadRequest(
            "invalid feedback value or reason".into(),
        ));
    }
    let target = target(&state, &user, article, &aspect, query).await?;
    super::briefs::mutation_response(
        feedback::write(
            &state.pool,
            user.id,
            &target,
            Some(vote.value),
            vote.reason.as_deref(),
            expected,
        )
        .await?,
    )
}

async fn undo(
    State(state): State<AppState>,
    user: AuthUser,
    Path((article, aspect)): Path<(Uuid, String)>,
    Query(query): Query<FeedbackQuery>,
    headers: HeaderMap,
) -> Result<(StatusCode, HeaderMap), ApiError> {
    let expected = super::briefs::expected_revision(&headers, true)?;
    let target = target(&state, &user, article, &aspect, query).await?;
    super::briefs::mutation_response(
        feedback::write(&state.pool, user.id, &target, None, None, expected).await?,
    )
}
