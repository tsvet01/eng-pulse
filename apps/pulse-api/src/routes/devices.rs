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
    environment: Option<String>,
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
    let environment = b.environment.as_deref().unwrap_or("production");
    if !matches!(environment, "sandbox" | "production") {
        return Err(ApiError::BadRequest(
            "environment must be sandbox|production".into(),
        ));
    }
    let owned = devices::upsert(
        &s.pool,
        user.id,
        &b.platform,
        b.token.trim(),
        b.app_version.as_deref(),
        environment,
    )
    .await?;
    if owned {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::Conflict("token registered to another account"))
    }
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
    devices::deactivate(&s.pool, user.id, b.token.trim()).await?;
    Ok(StatusCode::NO_CONTENT)
}
