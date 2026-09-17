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

const MAX_USES_RANGE: std::ops::RangeInclusive<i32> = 1..=1000;
const EXPIRES_IN_DAYS_RANGE: std::ops::RangeInclusive<i64> = 1..=365;

async fn mint(
    State(state): State<AppState>,
    AdminUser(admin): AdminUser,
    body: Option<Json<Mint>>,
) -> Result<(StatusCode, Json<invites::Invite>), ApiError> {
    let m = body.map(|b| b.0).unwrap_or_default();
    let max_uses = m.max_uses.unwrap_or(1);
    if !MAX_USES_RANGE.contains(&max_uses) {
        return Err(ApiError::BadRequest(format!(
            "max_uses must be between {} and {}",
            MAX_USES_RANGE.start(),
            MAX_USES_RANGE.end()
        )));
    }
    let expires_at = match m.expires_in_days {
        None => None,
        Some(d) if EXPIRES_IN_DAYS_RANGE.contains(&d) => {
            Some(chrono::Utc::now() + chrono::Duration::days(d))
        }
        Some(_) => {
            return Err(ApiError::BadRequest(format!(
                "expires_in_days must be between {} and {}",
                EXPIRES_IN_DAYS_RANGE.start(),
                EXPIRES_IN_DAYS_RANGE.end()
            )))
        }
    };
    let inv = invites::create(&state.pool, admin.id, max_uses, expires_at).await?;
    Ok((StatusCode::CREATED, Json(inv)))
}
