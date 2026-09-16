#![allow(dead_code)]
use axum::{
    body::Body,
    http::{header, Method, Request, Response},
    Router,
};
use http_body_util::BodyExt;
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use pulse_api::{auth::jwks::JwksCache, config::Config, routes, state::AppState};
use sqlx::PgPool;
use std::{collections::HashMap, sync::Arc};
use tower::ServiceExt;
use wiremock::{
    matchers::{method, path},
    Mock, MockServer, ResponseTemplate,
};

pub const TEST_KID: &str = "test-1";
pub const ISSUER: &str = "https://test.supabase.co/auth/v1";
pub const SERVICE_TOKEN: &str = "pipeline-test-token";

pub fn test_config(jwks_url: &str) -> Config {
    Config::from_map(&HashMap::from([
        ("DATABASE_URL".to_string(), "unused".to_string()),
        ("SUPABASE_JWKS_URL".to_string(), jwks_url.to_string()),
        ("SUPABASE_ISSUER".to_string(), ISSUER.to_string()),
        (
            "PIPELINE_SERVICE_TOKEN".to_string(),
            SERVICE_TOKEN.to_string(),
        ),
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
        serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::String(
            String::from_utf8_lossy(&bytes).into(),
        ))
    };
    (status, json)
}

// Throwaway P-256 key used only by tests (never deployed anywhere).
pub const TEST_PRIVATE_KEY_PEM: &str = "-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgJxc/EHDbOTEIdYMr
B4H4kdedH8ddbcy4ki0TsU5zRN+hRANCAASOTY0G0F081o3Mw8nNz3Jv0WTLHWwY
GKn94t4N0treNwVwkcXoEIDfgp77Sc8bH4CmfPxb2bVnbHGAr/UhiaD7
-----END PRIVATE KEY-----";
pub const TEST_JWK_X: &str = "jk2NBtBdPNaNzMPJzc9yb9Fkyx1sGBip_eLeDdLa3jc";
pub const TEST_JWK_Y: &str = "BXCRxegQgN-CnvtJzxsfgKZ8_FvZtWdscYCv9SGJoPs";

pub fn jwks_json() -> serde_json::Value {
    serde_json::json!({"keys":[{"kty":"EC","crv":"P-256","alg":"ES256","use":"sig","kid":TEST_KID,"x":TEST_JWK_X,"y":TEST_JWK_Y}]})
}

/// Starts a JWKS server; returns (server, jwks_url).
pub async fn jwks_mock() -> (MockServer, String) {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/jwks"))
        .respond_with(ResponseTemplate::new(200).set_body_json(jwks_json()))
        .mount(&server)
        .await;
    let url = format!("{}/jwks", server.uri());
    (server, url)
}

pub struct TokenOpts {
    pub sub: String,
    pub email: Option<String>,
    pub verified: bool,
    pub exp_offset_secs: i64,
    pub kid: String,
    pub aud: String,
    pub iss: String,
}

impl Default for TokenOpts {
    fn default() -> Self {
        Self {
            sub: uuid::Uuid::new_v4().to_string(),
            email: Some("user@example.com".into()),
            verified: true,
            exp_offset_secs: 3600,
            kid: TEST_KID.into(),
            aud: "authenticated".into(),
            iss: ISSUER.into(),
        }
    }
}

pub fn token(o: TokenOpts) -> String {
    let now = chrono::Utc::now().timestamp();
    let claims = serde_json::json!({
        "sub": o.sub, "iss": o.iss, "aud": o.aud, "exp": now + o.exp_offset_secs, "iat": now,
        "email": o.email, "user_metadata": {"email_verified": o.verified}, "role": "authenticated"
    });
    let mut header = Header::new(Algorithm::ES256);
    header.kid = Some(o.kid);
    encode(
        &header,
        &claims,
        &EncodingKey::from_ec_pem(TEST_PRIVATE_KEY_PEM.as_bytes()).unwrap(),
    )
    .unwrap()
}

pub fn user_token(sub: &str, email: &str) -> String {
    token(TokenOpts {
        sub: sub.into(),
        email: Some(email.into()),
        ..Default::default()
    })
}

/// Registers a user directly in the DB (bypassing invites) and returns (user_id, bearer token).
pub async fn registered_user(pool: &PgPool, email: &str, is_admin: bool) -> (uuid::Uuid, String) {
    let sub = uuid::Uuid::new_v4().to_string();
    let id: uuid::Uuid =
        sqlx::query_scalar("insert into users (email, is_admin) values ($1, $2) returning id")
            .bind(email)
            .bind(is_admin)
            .fetch_one(pool)
            .await
            .unwrap();
    sqlx::query("insert into identities (user_id, issuer, subject) values ($1, $2, $3)")
        .bind(id)
        .bind(ISSUER)
        .bind(&sub)
        .execute(pool)
        .await
        .unwrap();
    (id, user_token(&sub, email))
}
