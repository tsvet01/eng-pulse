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
    engineering_feed(&pool).await;
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
    engineering_feed(&pool).await;
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

/// An empty `email` claim is no email: it must not slip past the check and
/// match an unset ADMIN_EMAIL.
#[sqlx::test]
async fn signup_rejects_empty_email_claim(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "EMPTY", 1, false).await;
    let app = app(pool.clone(), &url);
    let t = token(TokenOpts {
        email: Some("   ".into()),
        ..Default::default()
    });
    let (status, body) = send(
        &app,
        Method::POST,
        "/v1/users",
        Some(&t),
        Some(json!({"invite_code": "EMPTY"})),
    )
    .await;
    assert_eq!(status, 422);
    assert_eq!(body["message"], "token has no email");
    let n: i64 = sqlx::query_scalar("select count(*) from users")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(n, 0);
}

#[sqlx::test]
async fn duplicate_identity_signup_is_idempotent(pool: PgPool) {
    engineering_feed(&pool).await;
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

#[sqlx::test]
async fn invite_cannot_link_another_identity_by_email(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    engineering_feed(&pool).await;
    let app = app(pool.clone(), &url);
    for (email, admin) in [("reader@example.com", false), ("admin@example.com", true)] {
        let (id, original) = registered_user(&pool, email, admin).await;
        invite(&pool, email, 1, false).await;
        let stranger = user_token("different-provider-subject", &email.to_uppercase());
        let (status, _) = send(
            &app,
            Method::POST,
            "/v1/users",
            Some(&stranger),
            Some(json!({"invite_code": email})),
        )
        .await;
        assert_eq!(status, 409);
        assert_eq!(
            send(&app, Method::GET, "/v1/me", Some(&stranger), None)
                .await
                .0,
            403
        );
        assert_eq!(
            send(
                &app,
                Method::POST,
                "/admin/invites",
                Some(&stranger),
                Some(json!({}))
            )
            .await
            .0,
            403
        );
        let (status, body) = send(&app, Method::GET, "/v1/me", Some(&original), None).await;
        assert_eq!(status, 200);
        assert_eq!(body["id"], id.to_string());
        let used: i32 = sqlx::query_scalar("select used_count from invites where code = $1")
            .bind(email)
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(used, 0);
        let identities: i64 =
            sqlx::query_scalar("select count(*) from identities where user_id = $1")
                .bind(id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(identities, 1);
    }
}

#[sqlx::test]
async fn signup_enrolls_once_and_preserves_preferences_and_departure(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let fid = engineering_feed(&pool).await;
    invite(&pool, "PILOT", 2, false).await;
    let app = app(pool.clone(), &url);
    let t = user_token("new-reader", "reader@example.com");
    let signup = json!({"invite_code": "PILOT"});
    assert_eq!(
        send(
            &app,
            Method::POST,
            "/v1/users",
            Some(&t),
            Some(signup.clone())
        )
        .await
        .0,
        201
    );
    let (_, feeds) = send(&app, Method::GET, "/v1/feeds", Some(&t), None).await;
    assert_eq!(feeds[0]["member"], true);
    assert_eq!(feeds[0]["role"], "member");
    let membership = format!("/v1/feeds/{fid}/membership");
    assert_eq!(
        send(
            &app,
            Method::POST,
            &membership,
            Some(&t),
            Some(json!({"notify_email": false, "notify_push": false}))
        )
        .await
        .0,
        200
    );
    assert_eq!(
        send(
            &app,
            Method::POST,
            "/v1/users",
            Some(&t),
            Some(signup.clone())
        )
        .await
        .0,
        200
    );
    let prefs: (bool, bool) =
        sqlx::query_as("select notify_email, notify_push from memberships where feed_id = $1")
            .bind(fid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(prefs, (false, false));
    assert_eq!(
        send(&app, Method::DELETE, &membership, Some(&t), None)
            .await
            .0,
        204
    );
    assert_eq!(
        send(&app, Method::POST, "/v1/users", Some(&t), Some(signup))
            .await
            .0,
        200
    );
    let (_, feeds) = send(&app, Method::GET, "/v1/feeds", Some(&t), None).await;
    assert_eq!(feeds[0]["member"], false);
    let used: i32 = sqlx::query_scalar("select used_count from invites where code = 'PILOT'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(used, 1);
}

#[sqlx::test]
async fn unavailable_feed_rolls_back_signup_and_invite(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "PILOT", 1, false).await;
    let app = app(pool.clone(), &url);
    let t = user_token("reader", "reader@example.com");
    for inactive in [false, true] {
        if inactive {
            engineering_feed(&pool).await;
            sqlx::query("update feeds set is_active = false")
                .execute(&pool)
                .await
                .unwrap();
        }
        assert_eq!(
            send(
                &app,
                Method::POST,
                "/v1/users",
                Some(&t),
                Some(json!({"invite_code": "PILOT"}))
            )
            .await
            .0,
            503
        );
        let n: i64 = sqlx::query_scalar("select count(*) from users")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(n, 0);
        let n: i64 = sqlx::query_scalar("select count(*) from identities")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(n, 0);
        let used: i32 = sqlx::query_scalar("select used_count from invites where code = 'PILOT'")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(used, 0);
    }
}

#[sqlx::test]
async fn disabled_user_cannot_use_existing_token_or_signup_again(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let fid = engineering_feed(&pool).await;
    let (uid, t) = registered_user(&pool, "admin@example.com", true).await;
    invite(&pool, "PILOT", 1, false).await;
    let app = app(pool.clone(), &url);
    assert_eq!(
        send(&app, Method::GET, "/v1/me", Some(&t), None).await.0,
        200
    );
    sqlx::query("update users set is_active = false where id = $1")
        .bind(uid)
        .execute(&pool)
        .await
        .unwrap();
    for (method, path, body) in [
        (Method::GET, "/v1/me".into(), None),
        (Method::GET, "/v1/feeds".into(), None),
        (
            Method::POST,
            format!("/v1/feeds/{fid}/membership"),
            Some(json!({})),
        ),
        (Method::POST, "/admin/invites".into(), Some(json!({}))),
        (
            Method::POST,
            "/v1/users".into(),
            Some(json!({"invite_code": "PILOT"})),
        ),
    ] {
        assert_eq!(
            send(&app, method, &path, Some(&t), body).await.0,
            403,
            "{path}"
        );
    }
    let new_identity = user_token("new-sub", "admin@example.com");
    assert_eq!(
        send(
            &app,
            Method::POST,
            "/v1/users",
            Some(&new_identity),
            Some(json!({"invite_code": "PILOT"}))
        )
        .await
        .0,
        409
    );
    let used: i32 = sqlx::query_scalar("select used_count from invites where code = 'PILOT'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(used, 0);
}
