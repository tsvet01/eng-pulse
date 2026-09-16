// Not yet used outside tests; wired into handlers starting Task 2.
#![allow(dead_code)]

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    Unauthorized(&'static str),
    InviteRequired,
    Forbidden,
    NotFound(&'static str),
    Conflict(&'static str),
    BadRequest(String),
    Db(sqlx::Error),
    Internal(String),
}

impl ApiError {
    fn parts(&self) -> (StatusCode, &str, String) {
        match self {
            Self::Unauthorized(m) => (StatusCode::UNAUTHORIZED, "unauthorized", m.to_string()),
            Self::InviteRequired => (
                StatusCode::FORBIDDEN,
                "invite_required",
                "sign-up needs an invite code".into(),
            ),
            Self::Forbidden => (StatusCode::FORBIDDEN, "forbidden", "not allowed".into()),
            Self::NotFound(m) => (StatusCode::NOT_FOUND, "not_found", m.to_string()),
            Self::Conflict(m) => (StatusCode::CONFLICT, "conflict", m.to_string()),
            Self::BadRequest(m) => (StatusCode::UNPROCESSABLE_ENTITY, "bad_request", m.clone()),
            Self::Db(e) => (StatusCode::INTERNAL_SERVER_ERROR, "db_error", e.to_string()),
            Self::Internal(m) => (StatusCode::INTERNAL_SERVER_ERROR, "internal", m.clone()),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code, message) = self.parts();
        if status.is_server_error() {
            tracing::error!(code, %message, "request failed");
        }
        let body = if status.is_server_error() {
            json!({"error": code})
        } else {
            json!({"error": code, "message": message})
        };
        (status, Json(body)).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => Self::NotFound("not found"),
            other => Self::Db(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn invite_required_is_403_with_code() {
        let resp = ApiError::InviteRequired.into_response();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);
        let body = axum::body::to_bytes(resp.into_body(), 1024).await.unwrap();
        assert_eq!(
            serde_json::from_slice::<serde_json::Value>(&body).unwrap()["error"],
            "invite_required"
        );
    }

    #[tokio::test]
    async fn db_errors_hide_details() {
        let resp = ApiError::Internal("secret detail".into()).into_response();
        let body = axum::body::to_bytes(resp.into_body(), 1024).await.unwrap();
        assert!(!String::from_utf8_lossy(&body).contains("secret detail"));
    }
}
