mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test]
async fn device_upsert_and_delete(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "d@example.com", false).await;
    let app = app(pool.clone(), &url);
    for ver in ["1.0", "1.1"] {
        let (status, _) = send(
            &app,
            Method::PUT,
            "/v1/devices",
            Some(&t),
            Some(json!({"platform": "ios", "token": "tok-1", "app_version": ver})),
        )
        .await;
        assert_eq!(status, 204);
    }
    let (n, ver): (i64, String) =
        sqlx::query_as("select count(*), max(app_version) from device_tokens where user_id = $1")
            .bind(uid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!((n, ver.as_str()), (1, "1.1"));
    let (status, _) = send(
        &app,
        Method::PUT,
        "/v1/devices",
        Some(&t),
        Some(json!({"platform": "web", "token": "x"})),
    )
    .await;
    assert_eq!(status, 422);
    let (status, _) = send(
        &app,
        Method::DELETE,
        "/v1/devices",
        Some(&t),
        Some(json!({"token": "tok-1"})),
    )
    .await;
    assert_eq!(status, 204);
    let n: i64 =
        sqlx::query_scalar("select count(*) from device_tokens where user_id = $1 and is_active")
            .bind(uid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(n, 0);
}
