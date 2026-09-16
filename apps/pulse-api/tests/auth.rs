mod common;
use axum::http::Method;
use common::*;
use sqlx::PgPool;

#[sqlx::test]
async fn missing_token_is_401(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::GET, "/v1/me", None, None).await;
    assert_eq!(status, 401);
    assert_eq!(body["error"], "unauthorized");
}

#[sqlx::test]
async fn expired_token_is_401(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let t = token(TokenOpts {
        exp_offset_secs: -10,
        ..Default::default()
    });
    let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 401);
}

#[sqlx::test]
async fn wrong_issuer_or_audience_is_401(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    for t in [
        token(TokenOpts {
            iss: "https://other".into(),
            ..Default::default()
        }),
        token(TokenOpts {
            aud: "anon".into(),
            ..Default::default()
        }),
    ] {
        let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
        assert_eq!(status, 401);
    }
}

#[sqlx::test]
async fn unknown_kid_is_401_after_refresh(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let t = token(TokenOpts {
        kid: "nope".into(),
        ..Default::default()
    });
    let (status, body) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 401);
    assert_eq!(body["message"], "unknown key id");
}

#[sqlx::test]
async fn valid_token_without_account_is_invite_required(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let (status, body) = send(
        &app,
        Method::GET,
        "/v1/me",
        Some(&user_token("sub-1", "new@example.com")),
        None,
    )
    .await;
    assert_eq!(status, 403);
    assert_eq!(body["error"], "invite_required");
}

#[sqlx::test]
async fn registered_user_gets_me(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (id, t) = registered_user(&pool, "me@example.com", false).await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 200);
    assert_eq!(body["id"], id.to_string());
    assert_eq!(body["is_admin"], false);
}

#[sqlx::test]
async fn verified_email_links_new_identity(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (id, _) = registered_user(&pool, "link@example.com", false).await;
    let app = app(pool.clone(), &url);
    let second = user_token("second-provider-sub", "link@example.com");
    let (status, body) = send(&app, Method::GET, "/v1/me", Some(&second), None).await;
    assert_eq!(status, 200);
    assert_eq!(body["id"], id.to_string());
    let n: i64 = sqlx::query_scalar("select count(*) from identities where user_id = $1")
        .bind(id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(n, 2);
}

#[sqlx::test]
async fn email_match_is_case_insensitive(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (id, _) = registered_user(&pool, "Mixed.Case@Example.com", false).await;
    let app = app(pool, &url);
    let t = user_token("case-sub", "mixed.case@example.com");
    let (status, body) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 200);
    assert_eq!(body["id"], id.to_string());
}

#[sqlx::test]
async fn unverified_email_does_not_link(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    registered_user(&pool, "nolink@example.com", false).await;
    let app = app(pool, &url);
    let t = token(TokenOpts {
        sub: "x".into(),
        email: Some("nolink@example.com".into()),
        verified: false,
        ..Default::default()
    });
    let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 403);
}

#[sqlx::test]
async fn internal_requires_service_token(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let (s1, _) = send(&app, Method::GET, "/internal/feeds", None, None).await;
    let (s2, _) = send(&app, Method::GET, "/internal/feeds", Some("wrong"), None).await;
    let (s3, _) = send(
        &app,
        Method::GET,
        "/internal/feeds",
        Some(SERVICE_TOKEN),
        None,
    )
    .await;
    assert_eq!((s1, s2, s3), (401, 401, 200));
}
