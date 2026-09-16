mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

fn brief(date: &str, title: &str) -> serde_json::Value {
    json!({"feed_slug": "engineering", "date": date, "format": "insight-brief-v3",
        "payload": {"key_idea": "k", "why_it_matters": "w", "what_to_change": null, "deep_dive": "d", "meta": {"confidence": 0.9, "category": "platform-engineering"}},
        "article_url": "https://example.com/a", "article_title": title, "model": "claude-opus-5", "eval_score": 0.95})
}

async fn seed_feed(pool: &PgPool) -> uuid::Uuid {
    let id: uuid::Uuid = sqlx::query_scalar(
        "insert into feeds (slug, name) values ('engineering','Engineering') returning id",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    sqlx::query("insert into feed_topics (feed_id, topic) values ($1, 'rust')")
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("insert into feed_sources (feed_id, url, kind) values ($1, 'https://blog.cloudflare.com/rss/', 'rss'), ($1, 'https://old.example/feed', 'rss')").bind(id).execute(pool).await.unwrap();
    sqlx::query("update feed_sources set is_active = false where url like '%old%'")
        .execute(pool)
        .await
        .unwrap();
    id
}

#[sqlx::test]
async fn internal_feeds_matches_contract(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    seed_feed(&pool).await;
    let app = app(pool, &url);
    let (status, body) = send(
        &app,
        Method::GET,
        "/internal/feeds",
        Some(SERVICE_TOKEN),
        None,
    )
    .await;
    assert_eq!(status, 200);
    let feeds: Vec<pulse_core::Feed> = serde_json::from_value(body).unwrap();
    assert_eq!(feeds[0].slug, "engineering");
    assert_eq!(feeds[0].topics, vec!["rust"]);
    assert_eq!(feeds[0].sources.len(), 1);
}

#[sqlx::test]
async fn brief_upsert_and_unknown_feed(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed_id = seed_feed(&pool).await;
    let app = app(pool.clone(), &url);
    let (status, body) = send(
        &app,
        Method::POST,
        "/internal/briefs",
        Some(SERVICE_TOKEN),
        Some(brief("2026-09-16", "first")),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["created"], true);
    let (status, body) = send(
        &app,
        Method::POST,
        "/internal/briefs",
        Some(SERVICE_TOKEN),
        Some(brief("2026-09-16", "second")),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["created"], false);
    let (title, payload): (String, serde_json::Value) =
        sqlx::query_as("select article_title, payload from briefs where feed_id = $1")
            .bind(feed_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(title, "second");
    assert_eq!(payload["key_idea"], "k");
    let mut b = brief("2026-09-16", "x");
    b["feed_slug"] = json!("nope");
    let (status, _) = send(
        &app,
        Method::POST,
        "/internal/briefs",
        Some(SERVICE_TOKEN),
        Some(b),
    )
    .await;
    assert_eq!(status, 404);
}

#[sqlx::test]
async fn runs_and_feedback_roundtrip(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let feed_id = seed_feed(&pool).await;
    let (user_id, _) = registered_user(&pool, "u@example.com", false).await;
    sqlx::query("insert into feedback (user_id, feed_id, date, aspect, value) values ($1, $2, '2026-09-15', 'brief', 1)").bind(user_id).bind(feed_id).execute(&pool).await.unwrap();
    let app = app(pool, &url);
    let run = json!({"date": "2026-09-16", "feeds": [
        {"feed_slug": "engineering", "status": "ok", "article_url": "https://example.com/a", "input_tokens": 10, "output_tokens": 5, "est_cost_usd": 0.01, "error": null},
        {"feed_slug": "ghost", "status": "failed", "article_url": null, "input_tokens": 0, "output_tokens": 0, "est_cost_usd": 0.0, "error": "x"}]});
    let (status, body) = send(
        &app,
        Method::POST,
        "/internal/runs",
        Some(SERVICE_TOKEN),
        Some(run),
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body["stored"], 1);
    assert_eq!(body["skipped"], json!(["ghost"]));
    let (status, body) = send(
        &app,
        Method::GET,
        "/internal/feedback?feed=engineering&since=2026-09-01",
        Some(SERVICE_TOKEN),
        None,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body[0]["aspect"], "brief");
    assert_eq!(body[0]["value"], 1);
}
