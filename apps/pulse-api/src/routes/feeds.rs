use crate::{auth::extractors::AuthUser, db::feeds, error::ApiError, state::AppState};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/feeds", get(list).post(read_only))
        .route("/v1/feeds/{id}/membership", post(join).delete(leave))
        .route(
            "/v1/feeds/{id}/preferences",
            get(preferences).put(set_preferences),
        )
        .route("/v1/feeds/{id}/topics", post(read_only))
        .route(
            "/v1/feeds/{id}/topics/{topic}",
            axum::routing::delete(read_only),
        )
        .route("/v1/feeds/{id}/sources", post(read_only).delete(read_only))
}

async fn preferences(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> Result<Json<feeds::NotificationPreferences>, ApiError> {
    if !feeds::exists(&s.pool, id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    Ok(Json(
        feeds::preferences(&s.pool, user.id, id)
            .await?
            .ok_or(ApiError::Forbidden)?,
    ))
}

async fn set_preferences(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(prefs): Json<feeds::NotificationPreferences>,
) -> Result<Json<feeds::NotificationPreferences>, ApiError> {
    if !feeds::exists(&s.pool, id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    Ok(Json(
        feeds::set_preferences(&s.pool, user.id, id, &prefs)
            .await?
            .ok_or(ApiError::Forbidden)?,
    ))
}

async fn list(State(s): State<AppState>, user: AuthUser) -> Result<Json<Vec<Value>>, ApiError> {
    let mut out = Vec::new();
    for f in feeds::list_for_user(&s.pool, user.id).await? {
        out.push(json!({
            "id": f.id, "slug": f.slug, "name": f.name, "description": f.description, "is_active": f.is_active,
            "member": f.role.is_some(), "role": f.role,
            "topics": feeds::topics(&s.pool, f.id).await?, "sources": feeds::sources(&s.pool, f.id).await?,
        }));
    }
    Ok(Json(out))
}

// The pilot's generation configuration is managed by the existing pipeline workflow.
async fn read_only(_user: AuthUser) -> Result<StatusCode, ApiError> {
    Err(ApiError::Forbidden)
}

#[derive(Deserialize, Default)]
struct Join {
    notify_email: Option<bool>,
    notify_push: Option<bool>,
}

async fn join(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    body: Option<Json<Join>>,
) -> Result<StatusCode, ApiError> {
    if !feeds::exists(&s.pool, id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    let j = body.map(|b| b.0).unwrap_or_default();
    feeds::upsert_membership(&s.pool, user.id, id, j.notify_email, j.notify_push).await?;
    Ok(StatusCode::OK)
}

async fn leave(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    if !feeds::exists(&s.pool, id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    feeds::delete_membership(&s.pool, user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}
