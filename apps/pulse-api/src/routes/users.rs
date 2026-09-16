use crate::{
    auth::extractors::{AuthUser, Identity},
    db::{invites, users},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/users", post(signup))
        .route("/v1/me", get(me))
}

#[derive(Deserialize)]
struct Signup {
    invite_code: String,
}

/// Sign-up with an invite code. Already-registered callers get their existing
/// record back (200) instead of re-consuming an invite.
///
/// No automatic account linking: attaching a new identity to an existing
/// email is only ever done here, and only because a valid invite was just
/// consumed in the same transaction.
async fn signup(
    State(state): State<AppState>,
    Identity(claims): Identity,
    Json(body): Json<Signup>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    if let Some(u) = users::find_by_identity(&state.pool, &claims.iss, &claims.sub).await? {
        return Ok((StatusCode::OK, Json(user_json(&u))));
    }
    let email = claims
        .email_lower()
        .ok_or_else(|| ApiError::BadRequest("token has no email".into()))?;
    let mut tx = state.pool.begin().await?;
    invites::consume(&mut tx, body.invite_code.trim())
        .await?
        .ok_or_else(|| ApiError::BadRequest("invite code is invalid, expired or used up".into()))?;
    let is_admin = state.cfg.admin_email.as_deref() == Some(email.as_str());
    let user = match users::find_by_email(&state.pool, &email).await? {
        Some(existing) => existing,
        None => users::insert_user(&mut tx, &email, is_admin).await?,
    };
    users::insert_identity(&mut tx, user.id, &claims.iss, &claims.sub).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(user_json(&user))))
}

async fn me(user: AuthUser) -> Json<Value> {
    Json(json!({"id": user.id, "email": user.email, "is_admin": user.is_admin}))
}

pub fn user_json(u: &users::User) -> Value {
    json!({"id": u.id, "email": u.email, "display_name": u.display_name, "is_admin": u.is_admin})
}
