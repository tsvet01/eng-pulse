mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

fn tok(c: char) -> String {
    c.to_string().repeat(64)
}

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
            Some(json!({"platform": "ios", "token": tok('1'), "app_version": ver})),
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
        Some(json!({"token": tok('1')})),
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

#[sqlx::test]
async fn device_token_cannot_be_taken_over(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid_a, t_a) = registered_user(&pool, "a@example.com", false).await;
    let (_, t_b) = registered_user(&pool, "b@example.com", false).await;
    let app = app(pool.clone(), &url);
    let (status, _) = send(
        &app,
        Method::PUT,
        "/v1/devices",
        Some(&t_a),
        Some(json!({"platform": "ios", "token": tok('a')})),
    )
    .await;
    assert_eq!(status, 204);
    let (status, _) = send(
        &app,
        Method::PUT,
        "/v1/devices",
        Some(&t_b),
        Some(json!({"platform": "ios", "token": tok('a')})),
    )
    .await;
    assert_eq!(status, 409);
    let owner: uuid::Uuid =
        sqlx::query_scalar("select user_id from device_tokens where token = $1")
            .bind(tok('a'))
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(owner, uid_a);
    let (status, _) = send(
        &app,
        Method::PUT,
        "/v1/devices",
        Some(&t_a),
        Some(json!({"platform": "ios", "token": tok('a'), "app_version": "2.0"})),
    )
    .await;
    assert_eq!(status, 204);
    let ver: Option<String> =
        sqlx::query_scalar("select app_version from device_tokens where token = $1")
            .bind(tok('a'))
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(ver.as_deref(), Some("2.0"));
}

#[sqlx::test]
async fn inactive_token_can_be_taken_over_but_active_cannot(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid_a, t_a) = registered_user(&pool, "a2@example.com", false).await;
    let (uid_b, t_b) = registered_user(&pool, "b2@example.com", false).await;
    let app = app(pool.clone(), &url);
    let put = |t: &String, tk: String, ver: &'static str| {
        let (app, t) = (&app, t.clone());
        async move {
            send(
                app,
                Method::PUT,
                "/v1/devices",
                Some(&t),
                Some(json!({"platform": "ios", "token": tk, "app_version": ver})),
            )
            .await
        }
    };
    let row = |tk: String| {
        let pool = pool.clone();
        async move {
            sqlx::query_as::<_, (uuid::Uuid, bool, Option<String>)>(
                "select user_id, is_active, app_version from device_tokens where token = $1",
            )
            .bind(tk)
            .fetch_one(&pool)
            .await
            .unwrap()
        }
    };

    assert_eq!(put(&t_a, tok('b'), "1").await.0, 204);
    let (status, _) = send(
        &app,
        Method::DELETE,
        "/v1/devices",
        Some(&t_a),
        Some(json!({"token": tok('b')})),
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(put(&t_b, tok('b'), "2").await.0, 204);
    assert_eq!(row(tok('b')).await, (uid_b, true, Some("2".into())));

    assert_eq!(put(&t_a, tok('c'), "1").await.0, 204);
    assert_eq!(put(&t_b, tok('c'), "2").await.0, 409);
    assert_eq!(row(tok('c')).await, (uid_a, true, Some("1".into())));
}

#[sqlx::test]
async fn device_environment_is_stored_validated_and_updated(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "env@example.com", false).await;
    let app = app(pool.clone(), &url);
    let put = |body| send(&app, Method::PUT, "/v1/devices", Some(&t), Some(body));
    let env = || async {
        sqlx::query_scalar::<_, String>("select environment from device_tokens where user_id = $1")
            .bind(uid)
            .fetch_one(&pool)
            .await
            .unwrap()
    };

    let (s, _) = put(json!({"platform": "ios", "token": tok('e')})).await;
    assert_eq!((s, env().await.as_str()), (204, "production"));
    let (s, _) = put(json!({"platform": "ios", "token": tok('e'), "environment": "sandbox"})).await;
    assert_eq!((s, env().await.as_str()), (204, "sandbox"));
    let (s, _) = put(json!({"platform": "ios", "token": tok('e'), "environment": "staging"})).await;
    assert_eq!((s, env().await.as_str()), (422, "sandbox"));
}

#[sqlx::test]
async fn ios_tokens_are_validated_and_lowercased(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "hex@example.com", false).await;
    let app = app(pool.clone(), &url);
    let put = |tok: String| {
        send(
            &app,
            Method::PUT,
            "/v1/devices",
            Some(&t),
            Some(json!({"platform": "ios", "token": tok})),
        )
    };
    for bad in [
        format!("{}/x", "a".repeat(64)),
        format!("{}?x=1", "a".repeat(64)),
        format!("{}..", "a".repeat(64)),
        "../../3/device/abcdef".repeat(4),
        format!("{}g", "a".repeat(64)),
        "a".repeat(63),
        "a".repeat(201),
    ] {
        assert_eq!(put(bad.clone()).await.0, 422, "{bad}");
    }
    let upper = "AB".repeat(32);
    assert_eq!(put(upper.clone()).await.0, 204);
    assert_eq!(put(upper.to_lowercase()).await.0, 204);
    let rows: Vec<String> =
        sqlx::query_scalar("select token from device_tokens where user_id = $1")
            .bind(uid)
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(rows, vec![upper.to_lowercase()]);
    let (s, _) = send(
        &app,
        Method::DELETE,
        "/v1/devices",
        Some(&t),
        Some(json!({"token": upper})),
    )
    .await;
    assert_eq!(s, 204);
    let n: i64 =
        sqlx::query_scalar("select count(*) from device_tokens where user_id = $1 and is_active")
            .bind(uid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(n, 0);
}
