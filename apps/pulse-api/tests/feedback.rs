mod common;
use axum::{
    body::Body,
    http::{HeaderMap, Method, Request},
    Router,
};
use common::*;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::PgPool;
use tower::ServiceExt;

const PATH: &str = "/v1/briefs/engineering/2026-10-18/feedback";

async fn setup(pool: &PgPool) -> (uuid::Uuid, String, String) {
    let (uid, token) = registered_user(pool, "a@example.com", false).await;
    let (other, other_token) = registered_user(pool, "b@example.com", false).await;
    let feed = engineering_feed(pool).await;
    for user in [uid, other] {
        sqlx::query("insert into memberships (user_id, feed_id) values ($1,$2)")
            .bind(user)
            .bind(feed)
            .execute(pool)
            .await
            .unwrap();
    }
    sqlx::query("insert into briefs (feed_id,date,format,payload,article_url,article_title) values ($1,'2026-10-18','insight-brief-v3','{}','https://e/article','Article')")
        .bind(feed).execute(pool).await.unwrap();
    (uid, token, other_token)
}

async fn request(
    app: &Router,
    method: Method,
    path: &str,
    token: &str,
    revision: Option<&str>,
    body: Option<Value>,
) -> (u16, HeaderMap, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {token}"));
    if let Some(revision) = revision {
        req = req.header("X-Expected-Revision", revision);
    }
    let req = if let Some(body) = body {
        req.header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    } else {
        req.body(Body::empty()).unwrap()
    };
    let response = app.clone().oneshot(req).await.unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes).unwrap()
    };
    (status, headers, body)
}

#[sqlx::test]
async fn reads_only_current_accounts_feedback(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, a, b) = setup(&pool).await;
    let app = app(pool, &url);
    let (status, _, empty) = request(&app, Method::GET, PATH, &a, None, None).await;
    assert_eq!(status, 200);
    assert_eq!(
        empty,
        json!({"selection":{"value":null,"revision":0},"brief":{"value":null,"revision":0}})
    );
    for (token, value) in [(&a, 1), (&b, -1)] {
        let (status, h, _) = request(
            &app,
            Method::PUT,
            PATH,
            token,
            Some("0"),
            Some(json!({"aspect":"selection","value":value})),
        )
        .await;
        assert_eq!(status, 204);
        assert_eq!(h["x-feedback-revision"], "1");
    }
    let (_, _, mine) = request(&app, Method::GET, PATH, &a, None, None).await;
    assert_eq!(mine["selection"], json!({"value":1,"revision":1}));
    assert_eq!(mine["brief"], json!({"value":null,"revision":0}));
    let (_, _, theirs) = request(&app, Method::GET, PATH, &b, None, None).await;
    assert_eq!(theirs["selection"], json!({"value":-1,"revision":1}));
}

#[sqlx::test]
async fn undo_preserves_revision_and_rejects_stale_resurrection(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool.clone(), &url);
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"brief","value":1}))
        )
        .await
        .0,
        204
    );
    let (status, h, _) = request(
        &app,
        Method::PUT,
        PATH,
        &token,
        Some("1"),
        Some(json!({"aspect":"brief","value":-1})),
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "2");
    let (status, h, _) = request(
        &app,
        Method::DELETE,
        &format!("{PATH}/brief"),
        &token,
        Some("2"),
        None,
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "3");
    let (_, _, body) = request(&app, Method::GET, PATH, &token, None, None).await;
    assert_eq!(body["brief"], json!({"value":null,"revision":3}));
    let (status, h, _) = request(
        &app,
        Method::DELETE,
        &format!("{PATH}/brief"),
        &token,
        Some("3"),
        None,
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "3");
    for revision in ["0", "1", "2"] {
        let (status, _, body) = request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some(revision),
            Some(json!({"aspect":"brief","value":1})),
        )
        .await;
        assert_eq!(status, 409);
        assert_eq!(body["error"], "feedback_conflict");
    }
    let (status, _, body) = request(
        &app,
        Method::GET,
        "/internal/feedback?feed=engineering&since=2026-10-01",
        SERVICE_TOKEN,
        None,
        None,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body, json!([]));
}

#[sqlx::test]
async fn compatibility_writes_advance_revision(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    for (value, revision) in [(1, "1"), (-1, "2")] {
        let (status, h, _) = request(
            &app,
            Method::PUT,
            PATH,
            &token,
            None,
            Some(json!({"aspect":"selection","value":value})),
        )
        .await;
        assert_eq!(status, 204);
        assert_eq!(h["x-feedback-revision"], revision);
    }
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("1"),
            Some(json!({"aspect":"selection","value":1}))
        )
        .await
        .0,
        409
    );
}

#[sqlx::test]
async fn concurrent_first_writes_have_one_winner(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    let (a, b) = tokio::join!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"selection","value":1}))
        ),
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"selection","value":-1}))
        )
    );
    let mut statuses = [a.0, b.0];
    statuses.sort();
    assert_eq!(statuses, [204, 409]);
    let (_, _, saved) = request(&app, Method::GET, PATH, &token, None, None).await;
    assert_eq!(saved["selection"]["revision"], 1);
    assert_eq!(saved["selection"]["value"], if a.0 == 204 { 1 } else { -1 });
}

#[sqlx::test]
async fn absent_record_rejects_nonzero_revision_and_undo_creates_tombstone(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    for method in [Method::PUT, Method::DELETE] {
        let path = if method == Method::PUT {
            PATH.to_owned()
        } else {
            format!("{PATH}/brief")
        };
        let body = if method == Method::PUT {
            Some(json!({"aspect":"brief","value":1}))
        } else {
            None
        };
        assert_eq!(
            request(&app, method, &path, &token, Some("8"), body)
                .await
                .0,
            409
        );
    }
    let (status, h, _) = request(
        &app,
        Method::DELETE,
        &format!("{PATH}/brief"),
        &token,
        Some("0"),
        None,
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "1");
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"brief","value":1}))
        )
        .await
        .0,
        409
    );
}

#[sqlx::test]
async fn invalid_mutations_leave_feedback_unchanged(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    for revision in ["-1", "bogus", "1.0", "+1", "9223372036854775808", ""] {
        assert_eq!(
            request(
                &app,
                Method::PUT,
                PATH,
                &token,
                Some(revision),
                Some(json!({"aspect":"brief","value":1}))
            )
            .await
            .0,
            422
        );
    }
    for body in [
        json!({"aspect":"invalid","value":1}),
        json!({"aspect":"brief","value":0}),
    ] {
        assert_eq!(
            request(&app, Method::PUT, PATH, &token, Some("0"), Some(body))
                .await
                .0,
            422
        );
    }
    assert_eq!(
        request(
            &app,
            Method::DELETE,
            &format!("{PATH}/brief"),
            &token,
            None,
            None
        )
        .await
        .0,
        422
    );
    assert_eq!(
        request(
            &app,
            Method::DELETE,
            &format!("{PATH}/invalid"),
            &token,
            Some("0"),
            None
        )
        .await
        .0,
        422
    );
    let (_, _, saved) = request(&app, Method::GET, PATH, &token, None, None).await;
    assert_eq!(saved["brief"]["revision"], 0);
}

#[sqlx::test]
async fn every_operation_enforces_membership_revocation_and_brief_existence(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (uid, token, _) = setup(&pool).await;
    let (_, outsider) = registered_user(&pool, "outsider@example.com", false).await;
    let app = app(pool.clone(), &url);
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        let suffix = if method == Method::DELETE {
            "/brief"
        } else {
            ""
        };
        let body = if method == Method::PUT {
            Some(json!({"aspect":"brief","value":1}))
        } else {
            None
        };
        assert_eq!(
            request(
                &app,
                method.clone(),
                &format!("{PATH}{suffix}"),
                &outsider,
                Some("0"),
                body.clone()
            )
            .await
            .0,
            403
        );
        assert_eq!(
            request(
                &app,
                method,
                &format!("{}{suffix}", PATH.replace("2026-10-18", "2026-10-17")),
                &token,
                Some("0"),
                body
            )
            .await
            .0,
            404
        );
    }
    sqlx::query("update users set is_active=false where id=$1")
        .bind(uid)
        .execute(&pool)
        .await
        .unwrap();
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        let path = if method == Method::DELETE {
            format!("{PATH}/brief")
        } else {
            PATH.to_owned()
        };
        let body = if method == Method::PUT {
            Some(json!({"aspect":"brief","value":1}))
        } else {
            None
        };
        assert_eq!(
            request(&app, method, &path, &token, Some("0"), body)
                .await
                .0,
            403
        );
    }
}
