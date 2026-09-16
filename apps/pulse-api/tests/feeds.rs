mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;
use wiremock::{
    matchers::{method, path},
    Mock, ResponseTemplate,
};

const RSS: &str = r#"<?xml version="1.0"?><rss version="2.0"><channel><title>T</title><link>http://x</link><description>d</description><item><title>a</title><link>http://x/a</link></item></channel></rss>"#;

#[sqlx::test]
async fn create_join_and_list(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, owner) = registered_user(&pool, "o@example.com", false).await;
    let (_, other) = registered_user(&pool, "m@example.com", false).await;
    let app = app(pool, &url);
    let (status, body) = send(
        &app,
        Method::POST,
        "/v1/feeds",
        Some(&owner),
        Some(json!({"slug": "rust", "name": "Rust", "description": "systems"})),
    )
    .await;
    assert_eq!(status, 201);
    let id = body["id"].as_str().unwrap().to_string();
    let (status, body) = send(&app, Method::GET, "/v1/feeds", Some(&other), None).await;
    assert_eq!(status, 200);
    assert_eq!(body[0]["member"], false);
    let (status, _) = send(
        &app,
        Method::POST,
        &format!("/v1/feeds/{id}/membership"),
        Some(&other),
        Some(json!({"notify_push": false})),
    )
    .await;
    assert_eq!(status, 200);
    let (_, body) = send(&app, Method::GET, "/v1/feeds", Some(&other), None).await;
    assert_eq!(body[0]["member"], true);
    assert_eq!(body[0]["role"], "member");
    let (_, body) = send(&app, Method::GET, "/v1/feeds", Some(&owner), None).await;
    assert_eq!(body[0]["role"], "owner");
    let (status, _) = send(
        &app,
        Method::DELETE,
        &format!("/v1/feeds/{id}/membership"),
        Some(&other),
        None,
    )
    .await;
    assert_eq!(status, 204);
}

#[sqlx::test]
async fn duplicate_slug_is_409(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "o@example.com", false).await;
    let app = app(pool, &url);
    send(
        &app,
        Method::POST,
        "/v1/feeds",
        Some(&t),
        Some(json!({"slug": "x", "name": "X"})),
    )
    .await;
    let (status, _) = send(
        &app,
        Method::POST,
        "/v1/feeds",
        Some(&t),
        Some(json!({"slug": "x", "name": "X2"})),
    )
    .await;
    assert_eq!(status, 409);
}

#[sqlx::test]
async fn topics_and_sources_require_membership(pool: PgPool) {
    let (server, url) = jwks_mock().await;
    Mock::given(method("GET"))
        .and(path("/feed.xml"))
        .respond_with(ResponseTemplate::new(200).set_body_string(RSS))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/page.html"))
        .respond_with(ResponseTemplate::new(200).set_body_string("<html>no feed</html>"))
        .mount(&server)
        .await;
    let (_, owner) = registered_user(&pool, "o@example.com", false).await;
    let (_, stranger) = registered_user(&pool, "s@example.com", false).await;
    let app = app(pool, &url);
    let (_, body) = send(
        &app,
        Method::POST,
        "/v1/feeds",
        Some(&owner),
        Some(json!({"slug": "f", "name": "F"})),
    )
    .await;
    let id = body["id"].as_str().unwrap().to_string();
    let (status, _) = send(
        &app,
        Method::POST,
        &format!("/v1/feeds/{id}/topics"),
        Some(&stranger),
        Some(json!({"topic": "wasm"})),
    )
    .await;
    assert_eq!(status, 403);
    let (status, _) = send(
        &app,
        Method::POST,
        &format!("/v1/feeds/{id}/topics"),
        Some(&owner),
        Some(json!({"topic": " WASM "})),
    )
    .await;
    assert_eq!(status, 201);
    let feed_url = format!("{}/feed.xml", server.uri());
    let (status, body) = send(
        &app,
        Method::POST,
        &format!("/v1/feeds/{id}/sources"),
        Some(&owner),
        Some(json!({"url": feed_url})),
    )
    .await;
    assert_eq!(status, 201);
    assert_eq!(body["kind"], "rss");
    let (status, body) = send(
        &app,
        Method::POST,
        &format!("/v1/feeds/{id}/sources"),
        Some(&owner),
        Some(json!({"url": format!("{}/page.html", server.uri())})),
    )
    .await;
    assert_eq!(status, 422);
    assert!(body["message"]
        .as_str()
        .unwrap()
        .contains("not an RSS or Atom feed"));
    let (_, body) = send(&app, Method::GET, "/v1/feeds", Some(&owner), None).await;
    assert_eq!(body[0]["topics"], json!(["wasm"]));
    assert_eq!(body[0]["sources"][0]["kind"], "rss");
    let (status, _) = send(
        &app,
        Method::DELETE,
        &format!("/v1/feeds/{id}/topics/wasm"),
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, 204);
    let (status, _) = send(
        &app,
        Method::DELETE,
        &format!(
            "/v1/feeds/{id}/sources?url={}",
            urlencoding::encode(&feed_url)
        ),
        Some(&owner),
        None,
    )
    .await;
    assert_eq!(status, 204);
}
