mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

async fn invite(pool: &PgPool, code: &str, max_uses: i32, expired: bool) {
    let exp = if expired {
        "now() - interval '1 day'"
    } else {
        "now() + interval '30 days'"
    };
    sqlx::query(sqlx::AssertSqlSafe(format!(
        "insert into invites (code, max_uses, expires_at) values ($1, $2, {exp})"
    )))
    .bind(code)
    .bind(max_uses)
    .execute(pool)
    .await
    .unwrap();
}

#[sqlx::test]
async fn signup_with_invite_creates_user_and_identity(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "FRIENDS", 2, false).await;
    let app = app(pool.clone(), &url);
    let t = user_token("sub-a", "a@example.com");
    let (status, body) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "FRIENDS"})),
    )
    .await;
    assert_eq!(status, 201);
    assert_eq!(body["email"], "a@example.com");
    let used: i32 = sqlx::query_scalar("select used_count from invites where code = 'FRIENDS'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(used, 1);
    let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 200);
}

#[sqlx::test]
async fn signup_is_idempotent_for_registered_user(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "b@example.com", false).await;
    let app = app(pool, &url);
    let (status, _) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "whatever"})),
    )
    .await;
    assert_eq!(status, 200);
}

#[sqlx::test]
async fn bad_expired_or_exhausted_invite_is_422(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "OLD", 5, true).await;
    invite(&pool, "FULL", 0, false).await;
    let app = app(pool, &url);
    for code in ["missing", "OLD", "FULL"] {
        let t = user_token(&format!("sub-{code}"), &format!("{code}@example.com"));
        let (status, body) = send(
            &app,
            Method::POST,
            "/v1/users",
            Some(&t),
            Some(json!({"invite_code": code})),
        )
        .await;
        assert_eq!(status, 422, "{code}");
        assert_eq!(body["error"], "bad_request");
    }
}

#[sqlx::test]
async fn admin_email_becomes_admin_and_can_mint_invites(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "BOOT", 1, false).await;
    let app = app(pool, &url);
    let t = user_token("sub-admin", "admin@example.com"); // matches test_config ADMIN_EMAIL
    let (status, body) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "BOOT"})),
    )
    .await;
    assert_eq!(status, 201);
    assert_eq!(body["is_admin"], true);
    let (status, body) = send(
        &app,
        Method::POST,
        "/admin/invites",
        Some(&t),
        Some(json!({"max_uses": 5, "expires_in_days": 7})),
    )
    .await;
    assert_eq!(status, 201);
    assert_eq!(body["code"].as_str().unwrap().len(), 12);
    assert_eq!(body["max_uses"], 5);
}

#[sqlx::test]
async fn non_admin_cannot_mint_invites(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "plain@example.com", false).await;
    let app = app(pool, &url);
    let (status, _) = send(
        &app,
        Method::POST,
        "/admin/invites",
        Some(&t),
        Some(json!({})),
    )
    .await;
    assert_eq!(status, 403);
}

#[sqlx::test]
async fn signup_needs_email_in_token(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "X", 1, false).await;
    let app = app(pool, &url);
    let t = token(TokenOpts {
        email: None,
        ..Default::default()
    });
    let (status, _) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "X"})),
    )
    .await;
    assert_eq!(status, 422);
}

#[sqlx::test]
async fn duplicate_identity_signup_is_idempotent(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "FIRST", 1, false).await;
    invite(&pool, "SECOND", 1, false).await;
    let app = app(pool.clone(), &url);
    let t = user_token("sub-dup", "dup@example.com");
    let (status, _) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "FIRST"})),
    )
    .await;
    assert_eq!(status, 201);
    let (status, _) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "SECOND"})),
    )
    .await;
    assert_eq!(status, 200);
    let used: i32 = sqlx::query_scalar("select used_count from invites where code = 'SECOND'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(used, 0);
}

#[sqlx::test]
async fn invite_bounds_are_validated(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "admin@example.com", true).await;
    let app = app(pool, &url);
    for body in [
        json!({"expires_in_days": 0}),
        json!({"expires_in_days": 366}),
        json!({"max_uses": 0}),
        json!({"max_uses": 1001}),
    ] {
        let (status, resp) = send(
            &app,
            Method::POST,
            "/admin/invites",
            Some(&t),
            Some(body.clone()),
        )
        .await;
        assert_eq!(status, 422, "{body}");
        assert_eq!(resp["error"], "bad_request");
    }
    let (status, _) = send(
        &app,
        Method::POST,
        "/admin/invites",
        Some(&t),
        Some(json!({"max_uses": 5, "expires_in_days": 7})),
    )
    .await;
    assert_eq!(status, 201);
}
