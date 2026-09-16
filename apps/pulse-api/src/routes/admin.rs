use crate::{auth::extractors::AdminUser, db::invites, error::ApiError, state::AppState};
use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use serde::Deserialize;

pub fn routes() -> Router<AppState> {
    Router::new().route("/admin/invites", post(mint))
}

#[derive(Deserialize, Default)]
struct Mint {
    max_uses: Option<i32>,
    expires_in_days: Option<i64>,
}

async fn mint(
    State(state): State<AppState>,
    AdminUser(admin): AdminUser,
    body: Option<Json<Mint>>,
) -> Result<(StatusCode, Json<invites::Invite>), ApiError> {
    let m = body.map(|b| b.0).unwrap_or_default();
    let expires = m
        .expires_in_days
        .map(|d| chrono::Utc::now() + chrono::Duration::days(d));
    let inv = invites::create(
        &state.pool,
        admin.id,
        m.max_uses.unwrap_or(1).max(1),
        expires,
    )
    .await?;
    Ok((StatusCode::CREATED, Json(inv)))
}
