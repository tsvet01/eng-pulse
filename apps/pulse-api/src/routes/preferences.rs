use crate::{
    auth::extractors::AuthUser,
    db::{briefs, preferences},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::{Path, State},
    http::HeaderMap,
    routing::get,
    Json, Router,
};
use pulse_core::preferences::{topic_catalog, PreferenceChoices, PreferenceSnapshot};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v2/me/preferences", get(load).put(save))
        .route("/v2/briefs/{slug}/{date}/identity", get(identity))
}

async fn admitted(state: &AppState, user: &AuthUser) -> Result<(), ApiError> {
    let feed = briefs::feed_id_by_slug(&state.pool, "engineering")
        .await?
        .ok_or(ApiError::Forbidden)?;
    super::briefs::member_feed(state, user, feed).await
}

fn snapshot(row: preferences::PreferencesRow) -> Json<PreferenceSnapshot> {
    Json(PreferenceSnapshot {
        preferences: row.preferences.0,
        revision: row.revision,
        learned_reset_at: row.learned_reset_at.map(|t| t.to_rfc3339()),
        topics: topic_catalog(),
    })
}

async fn load(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<PreferenceSnapshot>, ApiError> {
    admitted(&state, &user).await?;
    Ok(snapshot(preferences::get(&state.pool, user.id).await?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Update {
    preferences: PreferenceChoices,
    #[serde(default)]
    reset_learned: bool,
}

async fn save(
    State(state): State<AppState>,
    user: AuthUser,
    headers: HeaderMap,
    Json(body): Json<Update>,
) -> Result<Json<PreferenceSnapshot>, ApiError> {
    admitted(&state, &user).await?;
    let expected = super::briefs::expected_revision(&headers, true)?.expect("required revision");
    if !body.preferences.is_valid() {
        return Err(ApiError::BadRequest("interests must be unique, separate from exclusions, with depth only for selected interests".into()));
    }
    let row = preferences::put(
        &state.pool,
        user.id,
        &body.preferences,
        expected,
        body.reset_learned,
    )
    .await?
    .ok_or(ApiError::PreferenceConflict)?;
    Ok(snapshot(row))
}

async fn identity(
    State(state): State<AppState>,
    user: AuthUser,
    Path((slug, date)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let feed = briefs::feed_id_by_slug(&state.pool, &slug)
        .await?
        .ok_or(ApiError::NotFound("feed"))?;
    super::briefs::member_feed(&state, &user, feed).await?;
    let date = super::briefs::parse_date(&date)?;
    let (article, brief): (Uuid, Uuid) = sqlx::query_as("select b.article_id,b.id from legacy_brief_identity l join article_briefs b on b.id=l.brief_id where l.feed_id=$1 and l.date=$2")
        .bind(feed).bind(date).fetch_optional(&state.pool).await?.ok_or(ApiError::NotFound("brief"))?;
    Ok(Json(json!({"article_id":article,"brief_id":brief})))
}
