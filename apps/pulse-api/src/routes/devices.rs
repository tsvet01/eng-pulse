use crate::{auth::extractors::AuthUser, db::devices, error::ApiError, state::AppState};
use axum::{extract::State, http::StatusCode, routing::put, Json, Router};
use serde::Deserialize;

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/devices", put(register).delete(remove))
}

#[derive(Deserialize)]
struct Register {
    platform: String,
    token: String,
    app_version: Option<String>,
}

async fn register(
    State(s): State<AppState>,
    user: AuthUser,
    Json(b): Json<Register>,
) -> Result<StatusCode, ApiError> {
    if !matches!(b.platform.as_str(), "ios" | "android") || b.token.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "platform must be ios|android and token non-empty".into(),
        ));
    }
    devices::upsert(
        &s.pool,
        user.id,
        &b.platform,
        b.token.trim(),
        b.app_version.as_deref(),
    )
    .await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct Remove {
    token: String,
}

async fn remove(
    State(s): State<AppState>,
    user: AuthUser,
    Json(b): Json<Remove>,
) -> Result<StatusCode, ApiError> {
    devices::deactivate(&s.pool, user.id, &b.token).await?;
    Ok(StatusCode::NO_CONTENT)
}
