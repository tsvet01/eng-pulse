use crate::{
    auth::claims::Claims,
    db::users::{self, User},
    error::ApiError,
    state::AppState,
};
use axum::{
    extract::FromRequestParts,
    http::{header, request::Parts},
};
use subtle::ConstantTimeEq;
use uuid::Uuid;

fn bearer(parts: &Parts) -> Result<&str, ApiError> {
    parts
        .headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|t| !t.is_empty())
        .ok_or(ApiError::Unauthorized("missing bearer token"))
}

/// A verified Supabase JWT; the caller may not be registered yet.
pub struct Identity(pub Claims);

impl FromRequestParts<AppState> for Identity {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer(parts)?;
        let claims = state
            .jwks
            .verify(
                token,
                &state.cfg.supabase_issuer,
                &state.cfg.supabase_audience,
            )
            .await?;
        Ok(Identity(claims))
    }
}

/// A registered user. Links a new identity when the verified email already has an account.
pub struct AuthUser {
    pub id: Uuid,
    pub email: String,
    pub is_admin: bool,
    pub claims: Claims,
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let Identity(claims) = Identity::from_request_parts(parts, state).await?;
        let user: User =
            match users::find_by_identity(&state.pool, &claims.iss, &claims.sub).await? {
                Some(u) => u,
                None => {
                    let linked = match claims.email_lower() {
                        Some(email) if claims.email_verified() => {
                            users::find_by_email(&state.pool, &email).await?
                        }
                        _ => None,
                    };
                    let Some(u) = linked else {
                        return Err(ApiError::InviteRequired);
                    };
                    users::link_identity(&state.pool, u.id, &claims.iss, &claims.sub).await?;
                    u
                }
            };
        Ok(AuthUser {
            id: user.id,
            email: user.email,
            is_admin: user.is_admin,
            claims,
        })
    }
}

pub struct AdminUser(pub AuthUser);

impl FromRequestParts<AppState> for AdminUser {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let u = AuthUser::from_request_parts(parts, state).await?;
        if u.is_admin {
            Ok(AdminUser(u))
        } else {
            Err(ApiError::Forbidden)
        }
    }
}

/// `/internal/*` caller: static pipeline token, constant-time compared.
pub struct ServiceToken;

impl FromRequestParts<AppState> for ServiceToken {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer(parts)?;
        let expected = state.cfg.pipeline_service_token.as_bytes();
        if token.len() == expected.len() && token.as_bytes().ct_eq(expected).into() {
            Ok(ServiceToken)
        } else {
            Err(ApiError::Unauthorized("bad service token"))
        }
    }
}
