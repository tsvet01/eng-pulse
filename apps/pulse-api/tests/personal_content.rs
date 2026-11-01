mod common;
use axum::{
    body::Body,
    http::{Method, Request},
    Router,
};
use common::*;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::PgPool;
use tower::ServiceExt;

const PREFS: &str = "/v2/me/preferences";
const IDENTITY: &str = "/v2/briefs/engineering/2026-11-01/identity";

async fn request(
    app: &Router,
    method: Method,
    path: &str,
    token: &str,
    revision: Option<&str>,
    body: Option<Value>,
) -> (u16, Value) {
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
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

fn preferences() -> Value {
    json!({"preferences": {"interests": ["cpu_performance", "platform"], "depth_by_topic": {"cpu_performance": "advanced"}, "excluded_topics": ["security"]}})
}

async fn setup(pool: &PgPool) -> (uuid::Uuid, String, String, uuid::Uuid) {
    let (a, at) = registered_user(pool, "a@example.com", false).await;
    let (b, bt) = registered_user(pool, "b@example.com", false).await;
    let feed = engineering_feed(pool).await;
    for user in [a, b] {
        sqlx::query("insert into memberships (user_id,feed_id) values ($1,$2)")
            .bind(user)
            .bind(feed)
            .execute(pool)
            .await
            .unwrap();
    }
    sqlx::query("insert into briefs (feed_id,date,format,payload,article_url,article_title,eval_score) values ($1,'2026-11-01','insight-brief-v3',$2,'https://example.com/article?id=1','Article',0.987654321)")
        .bind(feed).bind(json!({"deep_dive":"Original", "extra":{"preserve":[1,2,3]}})).execute(pool).await.unwrap();
    (a, at, bt, feed)
}

#[sqlx::test]
async fn preferences_are_private_revisioned_and_reset_preserves_explicit_choices(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, a, b, _) = setup(&pool).await;
    let app = app(pool, &url);
    let (status, empty) = request(&app, Method::GET, PREFS, &a, None, None).await;
    assert_eq!(status, 200);
    assert_eq!(empty["revision"], 0);
    assert_eq!(empty["topics"].as_array().unwrap().len(), 7);
    let (status, mine) =
        request(&app, Method::PUT, PREFS, &a, Some("0"), Some(preferences())).await;
    assert_eq!(status, 200);
    assert_eq!(mine["revision"], 1);
    assert_eq!(mine["preferences"], preferences()["preferences"]);
    let (_, theirs) = request(&app, Method::GET, PREFS, &b, None, None).await;
    assert_eq!(theirs["revision"], 0);
    assert_eq!(theirs["preferences"]["interests"], json!([]));
    let mut reset = preferences();
    reset["reset_learned"] = json!(true);
    let (status, reset) = request(&app, Method::PUT, PREFS, &a, Some("1"), Some(reset)).await;
    assert_eq!(status, 200);
    assert_eq!(reset["revision"], 2);
    assert_eq!(reset["preferences"], mine["preferences"]);
    assert!(reset["learned_reset_at"].is_string());
    let (_, changed) = request(&app, Method::PUT, PREFS, &a, Some("2"), Some(preferences())).await;
    assert_eq!(changed["learned_reset_at"], reset["learned_reset_at"]);
    let (status, error) =
        request(&app, Method::PUT, PREFS, &a, Some("1"), Some(preferences())).await;
    assert_eq!(status, 409);
    assert_eq!(error["error"], "preference_conflict");
}

#[sqlx::test]
async fn concurrent_first_preference_writes_do_not_overwrite(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, a, _, _) = setup(&pool).await;
    let app = app(pool, &url);
    let (one, two) = tokio::join!(
        request(&app, Method::PUT, PREFS, &a, Some("0"), Some(preferences())),
        request(&app, Method::PUT, PREFS, &a, Some("0"), Some(preferences()))
    );
    let mut statuses = [one.0, two.0];
    statuses.sort();
    assert_eq!(statuses, [200, 409]);
}

#[sqlx::test]
async fn invalid_preferences_and_account_fields_are_rejected(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, a, _, _) = setup(&pool).await;
    let app = app(pool, &url);
    for revision in [None, Some("-1"), Some("1.1"), Some("9223372036854775808")] {
        assert_eq!(
            request(&app, Method::PUT, PREFS, &a, revision, Some(preferences()))
                .await
                .0,
            422
        );
    }
    for (path, value) in [
        ("interests", json!(["unknown"])),
        ("interests", json!(["platform", "platform"])),
        ("excluded_topics", json!(["platform"])),
        ("depth_by_topic", json!({"cpu_performance":"expert"})),
        ("depth_by_topic", json!({"data":"advanced"})),
        ("user_id", json!("someone-else")),
    ] {
        let mut body = preferences();
        body["preferences"][path] = value;
        assert_eq!(
            request(&app, Method::PUT, PREFS, &a, Some("0"), Some(body))
                .await
                .0,
            422,
            "{path}"
        );
    }
    let mut body = preferences();
    body["user_id"] = json!("someone-else");
    assert_eq!(
        request(&app, Method::PUT, PREFS, &a, Some("0"), Some(body))
            .await
            .0,
        422
    );
}

#[sqlx::test]
async fn all_personal_content_routes_recheck_access(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (a, token, _, _) = setup(&pool).await;
    let app = app(pool.clone(), &url);
    for (method, path, body) in [
        (Method::GET, PREFS, None),
        (Method::GET, IDENTITY, None),
        (Method::PUT, PREFS, Some(preferences())),
    ] {
        assert_eq!(
            request(&app, method, path, "invalid", Some("0"), body)
                .await
                .0,
            401
        );
    }
    sqlx::query("delete from memberships where user_id=$1")
        .bind(a)
        .execute(&pool)
        .await
        .unwrap();
    for active in [true, false] {
        sqlx::query("update users set is_active=$2 where id=$1")
            .bind(a)
            .bind(active)
            .execute(&pool)
            .await
            .unwrap();
        for (method, path, body) in [
            (Method::GET, PREFS, None),
            (Method::GET, IDENTITY, None),
            (Method::PUT, PREFS, Some(preferences())),
        ] {
            assert_eq!(
                request(&app, method, path, &token, Some("0"), body).await.0,
                403
            );
        }
    }
}

#[sqlx::test]
async fn article_identity_survives_replay_and_brief_versions_preserve_payload(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _, feed) = setup(&pool).await;
    let app = app(pool.clone(), &url);
    let (status, original) = request(&app, Method::GET, IDENTITY, &token, None, None).await;
    assert_eq!(status, 200);
    sqlx::query("update briefs set payload=payload where feed_id=$1")
        .bind(feed)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        request(&app, Method::GET, IDENTITY, &token, None, None)
            .await
            .1,
        original
    );
    sqlx::query("update briefs set payload=$2 where feed_id=$1")
        .bind(feed)
        .bind(json!({"deep_dive":"Revised", "extra":{"preserve":[4]}}))
        .execute(&pool)
        .await
        .unwrap();
    let (_, revised) = request(&app, Method::GET, IDENTITY, &token, None, None).await;
    assert_eq!(original["article_id"], revised["article_id"]);
    assert_ne!(original["brief_id"], revised["brief_id"]);
    let original_id: uuid::Uuid = original["brief_id"].as_str().unwrap().parse().unwrap();
    let score: f64 =
        sqlx::query_scalar("select eval_score::double precision from article_briefs where id=$1")
            .bind(original_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(score, 0.987654321);
    let payload: Value = sqlx::query_scalar("select payload from article_briefs where id=$1")
        .bind(original_id)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(
        payload,
        json!({"deep_dive":"Original", "extra":{"preserve":[1,2,3]}})
    );
    assert!(
        sqlx::query("update article_briefs set payload='{}' where id=$1")
            .bind(original_id)
            .execute(&pool)
            .await
            .is_err()
    );
    // The same URL in another interest/date shares identity; query and fragment content IDs remain distinct.
    let other: uuid::Uuid = sqlx::query_scalar(
        "insert into feeds(slug,name) values('platform','Platform') returning id",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query("insert into briefs select $1,date,format,payload,article_url,article_title,model,eval_score,created_at from briefs where feed_id=$2").bind(other).bind(feed).execute(&pool).await.unwrap();
    let count: i64 = sqlx::query_scalar("select count(*) from articles")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 1);
    for url in [
        "https://example.com/article?id=2",
        "https://example.com/article?id=1#different-content",
    ] {
        sqlx::query("update briefs set article_url=$2 where feed_id=$1")
            .bind(other)
            .bind(url)
            .execute(&pool)
            .await
            .unwrap();
    }
    let count: i64 = sqlx::query_scalar("select count(*) from articles")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 3);
}

#[sqlx::test(migrations = false)]
async fn upgrade_backfills_existing_briefs_without_rewriting_feedback(pool: PgPool) {
    for migration in [
        include_str!("../migrations/0001_extensions.sql"),
        include_str!("../migrations/0002_schema.sql"),
        include_str!("../migrations/0003_pilot_readiness.sql"),
        include_str!("../migrations/0004_reconciliation.sql"),
        include_str!("../migrations/0005_feedback_revisions.sql"),
    ] {
        sqlx::raw_sql(migration).execute(&pool).await.unwrap();
    }
    let (user, _, _, feed) = setup(&pool).await;
    sqlx::query("insert into feedback(user_id,feed_id,date,aspect,value,revision) values($1,$2,'2026-11-01','selection',1,3)")
        .bind(user).bind(feed).execute(&pool).await.unwrap();
    sqlx::raw_sql(include_str!("../migrations/0006_personal_content.sql"))
        .execute(&pool)
        .await
        .unwrap();
    let before: (uuid::Uuid, uuid::Uuid) = sqlx::query_as(
        "select brief_id,original_brief_id from legacy_brief_identity where feed_id=$1",
    )
    .bind(feed)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query("update briefs set payload=payload")
        .execute(&pool)
        .await
        .unwrap();
    let after: (uuid::Uuid, uuid::Uuid) = sqlx::query_as(
        "select brief_id,original_brief_id from legacy_brief_identity where feed_id=$1",
    )
    .bind(feed)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(before, after);
    assert_eq!(before.0, before.1);
    let vote: (i16, i64) = sqlx::query_as("select value,revision from feedback where user_id=$1")
        .bind(user)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(vote, (1, 3));
    sqlx::query("update briefs set payload='{}'")
        .execute(&pool)
        .await
        .unwrap();
    let after: (uuid::Uuid, uuid::Uuid) = sqlx::query_as(
        "select brief_id,original_brief_id from legacy_brief_identity where feed_id=$1",
    )
    .bind(feed)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_ne!(after.0, before.0);
    assert_eq!(after.1, before.1);
}
