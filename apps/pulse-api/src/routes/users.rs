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
    let user = match users::find_by_email_tx(&mut tx, &email).await? {
        Some(existing) => existing,
        None => users::insert_user(&mut tx, &email, is_admin)
            .await
            .map_err(conflict_on_unique_violation)?,
    };
    users::insert_identity(&mut tx, user.id, &claims.iss, &claims.sub)
        .await
        .map_err(conflict_on_unique_violation)?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(user_json(&user))))
}

/// Two concurrent sign-ups for the same email (double-tap, retry after a
/// timeout) can both pass the pre-insert lookup and race on the `users.email`
/// or `identities` primary key; surface that as a retryable 409 instead of a
/// raw 500.
fn conflict_on_unique_violation(e: sqlx::Error) -> ApiError {
    match e.as_database_error() {
        Some(db) if db.is_unique_violation() => {
            ApiError::Conflict("sign-up already in progress, retry")
        }
        _ => e.into(),
    }
}

async fn me(user: AuthUser) -> Json<Value> {
    Json(json!({"id": user.id, "email": user.email, "is_admin": user.is_admin}))
}

pub fn user_json(u: &users::User) -> Value {
    json!({"id": u.id, "email": u.email, "display_name": u.display_name, "is_admin": u.is_admin})
}
