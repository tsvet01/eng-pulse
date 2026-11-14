use crate::{
    auth::extractors::AuthUser, db::devices, error::ApiError, notify::apns::is_apns_token,
    state::AppState,
};
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
    let ios = b.platform == "ios";
    if ios && !is_apns_token(b.token.trim()) {
        return Err(ApiError::BadRequest(
            "ios token must be 64-200 hex characters".into(),
        ));
    }
    let token = if ios {
        b.token.trim().to_ascii_lowercase()
    } else {
        b.token.trim().to_string()
    };
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
        &token,
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
    let t = b.token.trim();
    let t = if is_apns_token(t) {
        t.to_ascii_lowercase()
    } else {
        t.to_string()
    };
    devices::deactivate(&s.pool, user.id, &t).await?;
    Ok(StatusCode::NO_CONTENT)
}
