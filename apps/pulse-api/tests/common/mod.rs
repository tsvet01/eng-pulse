#![allow(dead_code)]
use axum::{
    body::Body,
    http::{header, Method, Request, Response},
    Router,
};
use http_body_util::BodyExt;
use pulse_api::{auth::jwks::JwksCache, config::Config, routes, state::AppState};
use sqlx::PgPool;
use std::{collections::HashMap, sync::Arc};
use tower::ServiceExt;

pub const TEST_KID: &str = "test-1";
pub const ISSUER: &str = "https://test.supabase.co/auth/v1";
pub const SERVICE_TOKEN: &str = "pipeline-test-token";

pub fn test_config(jwks_url: &str) -> Config {
    Config::from_map(&HashMap::from([
        ("DATABASE_URL".to_string(), "unused".to_string()),
        ("SUPABASE_JWKS_URL".to_string(), jwks_url.to_string()),
        ("SUPABASE_ISSUER".to_string(), ISSUER.to_string()),
        ("PIPELINE_SERVICE_TOKEN".to_string(), SERVICE_TOKEN.to_string()),
        ("ADMIN_EMAIL".to_string(), "admin@example.com".to_string()),
    ]))
    .unwrap()
}

pub fn app(pool: PgPool, jwks_url: &str) -> Router {
    let cfg = Arc::new(test_config(jwks_url));
    let jwks = Arc::new(JwksCache::new(jwks_url.to_string(), reqwest::Client::new()));
    routes::router(AppState { pool, cfg, jwks })
}

pub async fn send(
    app: &Router,
    method: Method,
    path: &str,
    bearer: Option<&str>,
    body: Option<serde_json::Value>,
) -> (u16, serde_json::Value) {
    let mut req = Request::builder().method(method).uri(path);
    if let Some(t) = bearer {
        req = req.header(header::AUTHORIZATION, format!("Bearer {t}"));
    }
    let req = match body {
        Some(b) => req
            .header(header::CONTENT_TYPE, "application/json")
            .body(Body::from(b.to_string()))
            .unwrap(),
        None => req.body(Body::empty()).unwrap(),
    };
    let resp: Response<Body> = app.clone().oneshot(req).await.unwrap();
    let status = resp.status().as_u16();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json = if bytes.is_empty() {
        serde_json::Value::Null
    } else {
        serde_json::from_slice(&bytes)
            .unwrap_or(serde_json::Value::String(String::from_utf8_lossy(&bytes).into()))
    };
    (status, json)
}
