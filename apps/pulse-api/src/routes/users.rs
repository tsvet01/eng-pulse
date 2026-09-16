use crate::{auth::extractors::AuthUser, state::AppState};
use axum::{routing::get, Json, Router};
use serde_json::json;

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/me", get(me))
}

async fn me(user: AuthUser) -> Json<serde_json::Value> {
    Json(json!({"id": user.id, "email": user.email, "is_admin": user.is_admin}))
}
