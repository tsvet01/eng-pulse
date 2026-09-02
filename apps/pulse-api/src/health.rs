use axum::{extract::State, http::StatusCode, Json};
use serde::Serialize;
use sqlx::PgPool;

#[derive(Serialize, Debug, PartialEq)]
pub struct Health {
    pub status: &'static str,
    pub db: &'static str,
}

pub fn health_body(db_ok: bool) -> (StatusCode, Json<Health>) {
    if db_ok {
        (
            StatusCode::OK,
            Json(Health {
                status: "ok",
                db: "ok",
            }),
        )
    } else {
        (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(Health {
                status: "degraded",
                db: "error",
            }),
        )
    }
}

pub async fn healthz(State(pool): State<PgPool>) -> (StatusCode, Json<Health>) {
    let db_ok = sqlx::query_scalar::<_, i32>("SELECT 1")
        .fetch_one(&pool)
        .await
        .is_ok();
    health_body(db_ok)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    #[test]
    fn healthy_when_db_ok() {
        let (status, body) = health_body(true);
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            body.0,
            Health {
                status: "ok",
                db: "ok"
            }
        );
    }

    #[test]
    fn degraded_when_db_down() {
        let (status, body) = health_body(false);
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(
            body.0,
            Health {
                status: "degraded",
                db: "error"
            }
        );
    }
}
