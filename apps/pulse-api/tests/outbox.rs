mod common;
use axum::http::Method;
use chrono::{Days, NaiveDate, Utc};
use common::*;
use pulse_api::history::{import_window, PublicArchive};
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;
use wiremock::{
    matchers::{method, path},
    Mock, MockServer, ResponseTemplate,
};

fn today() -> NaiveDate {
    Utc::now().date_naive()
}
fn brief(date: NaiveDate) -> Value {
    json!({"feed_slug": "engineering", "date": date.to_string(), "format": "insight-brief-v3",
        "payload": {"key_idea": "k", "why_it_matters": "w", "what_to_change": null, "deep_dive": "d", "meta": {"confidence": 0.9, "category": "platform-engineering"}},
        "article_url": "https://example.com/a", "article_title": "t", "model": "claude-opus-5", "eval_score": 0.95})
}
async fn member(pool: &PgPool, feed: Uuid, email: &str, push: bool, active: bool) -> Uuid {
    let (id, _) = registered_user(pool, email, false).await;
    sqlx::query("update users set is_active=$2 where id=$1")
        .bind(id)
        .bind(active)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("insert into memberships(user_id,feed_id,notify_push) values($1,$2,$3)")
        .bind(id)
        .bind(feed)
        .bind(push)
        .execute(pool)
        .await
        .unwrap();
    id
}
async fn post(app: &axum::Router, date: NaiveDate) -> (u16, Value) {
    send(
        app,
        Method::POST,
        "/internal/briefs",
        Some(SERVICE_TOKEN),
        Some(brief(date)),
    )
    .await
}
async fn rows(pool: &PgPool) -> Vec<(Uuid, String, String)> {
    sqlx::query_as("select user_id, channel, state from notification_outbox order by 1")
        .fetch_all(pool)
        .await
        .unwrap()
}
const ON: &[(&str, &str)] = &[
    ("NOTIFY_PUSH_ENABLED", "true"),
    ("APNS_KEY_BASE64", "dGVzdA=="),
    ("APNS_KEY_ID", "KEYID"),
    ("APNS_TEAM_ID", "TEAMID"),
];

#[sqlx::test]
async fn ingest_today_enqueues_one_push_row_per_opted_in_member(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed = engineering_feed(&pool).await;
    let a = member(&pool, feed, "a@example.com", true, true).await;
    member(&pool, feed, "b@example.com", false, true).await;
    let app = app_with(pool.clone(), &url, ON);
    let (status, _) = post(&app, today()).await;
    assert_eq!(status, 200);
    assert_eq!(rows(&pool).await, [(a, "push".into(), "pending".into())]);
}

#[sqlx::test]
async fn repost_of_today_does_not_enqueue_or_reset(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed = engineering_feed(&pool).await;
    let a = member(&pool, feed, "a@example.com", true, true).await;
    let app = app_with(pool.clone(), &url, ON);
    post(&app, today()).await;
    sqlx::query("update notification_outbox set state='sent'")
        .execute(&pool)
        .await
        .unwrap();
    let (status, body) = post(&app, today()).await;
    assert_eq!((status, &body["created"]), (200, &json!(false)));
    assert_eq!(rows(&pool).await, [(a, "push".into(), "sent".into())]);
}

#[sqlx::test]
async fn flag_off_enqueues_nothing(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed = engineering_feed(&pool).await;
    member(&pool, feed, "a@example.com", true, true).await;
    let app = app_with(pool.clone(), &url, &[]);
    let (status, body) = post(&app, today()).await;
    assert_eq!((status, &body["created"]), (200, &json!(true)));
    assert!(rows(&pool).await.is_empty());
}

#[sqlx::test]
async fn inactive_user_gets_no_row(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed = engineering_feed(&pool).await;
    member(&pool, feed, "a@example.com", true, false).await;
    let app = app_with(pool.clone(), &url, ON);
    post(&app, today()).await;
    assert!(rows(&pool).await.is_empty());
}

#[sqlx::test]
async fn past_date_ingest_is_silent(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed = engineering_feed(&pool).await;
    member(&pool, feed, "a@example.com", true, true).await;
    let app = app_with(pool.clone(), &url, ON);
    let (status, _) = post(&app, today().pred_opt().unwrap()).await;
    assert_eq!(status, 200);
    assert!(rows(&pool).await.is_empty());
}

#[sqlx::test]
async fn history_import_enqueues_only_today(pool: PgPool) {
    let feed = engineering_feed(&pool).await;
    let a = member(&pool, feed, "a@example.com", true, true).await;
    let end = today();
    let dates = [end.checked_sub_days(Days::new(1)).unwrap(), end];
    let server = MockServer::start().await;
    let entries: Vec<Value> = dates.iter().map(|d| json!({"date":d.to_string(),
        "url":format!("{}/archive/summaries/v3/{d}.json",server.uri()),"title":"T",
        "original_url":"https://example.org/a","model":"m","eval_score":0.9,"format":"insight-brief-v3"})).collect();
    let meta = |name: String, created: &'static str| {
        Mock::given(path(format!(
            "/storage/v1/b/archive/o/{}",
            urlencoding::encode(&name)
        )))
        .respond_with(
            ResponseTemplate::new(200)
                .set_body_json(json!({"generation":"123","timeCreated":created})),
        )
    };
    let body = |p: String, b: Value| {
        Mock::given(method("GET")).and(path(p)).respond_with(
            ResponseTemplate::new(200)
                .insert_header("x-goog-generation", "123")
                .set_body_json(b),
        )
    };
    meta("manifest.json".into(), "2026-10-17T12:00:00.500Z")
        .mount(&server)
        .await;
    body("/archive/manifest.json".into(), json!(entries))
        .mount(&server)
        .await;
    for d in dates {
        meta(format!("summaries/v3/{d}.json"), "2026-10-17T12:00:00.100Z")
            .mount(&server)
            .await;
        body(
            format!("/archive/summaries/v3/{d}.json"),
            json!({"deep_dive":"Brief"}),
        )
        .mount(&server)
        .await;
    }
    let source = PublicArchive::new(format!("{}/archive/", server.uri()).parse().unwrap()).unwrap();
    let report = import_window(&pool, &source, end, true).await.unwrap();
    assert_eq!(report.inserted, 2);
    let dated: Vec<(Uuid, NaiveDate)> =
        sqlx::query_as("select user_id, date from notification_outbox")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(dated, [(a, end)]);
    let replay = import_window(&pool, &source, end, true).await.unwrap();
    assert_eq!(replay.inserted, 0);
    assert_eq!(rows(&pool).await.len(), 1);
}
