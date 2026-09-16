# Phase 1: API MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the `pulse-api` skeleton into the multi-user API: Supabase-JWT auth with an invite gate, feeds/memberships/topics/sources, brief ingest and read, feedback, devices; seed the `engineering` feed; make the daily pipeline dual-write briefs to the API. Notification fan-out stays off.

**Architecture:** axum 0.8 + sqlx 0.9 on the Hetzner box (Phase 0). Three route groups: `/v1` (Supabase JWT → `user_id`), `/internal` (static service token, pipeline), `/admin` (JWT + `is_admin`). JWTs are verified locally against a cached JWKS. Each aggregate has a `db/*.rs` query module and a `routes/*.rs` handler module; handlers are thin. The daily agent keeps writing GCS + manifest and additionally `POST`s the same brief to `/internal/briefs`.

**Tech Stack:** Rust 1.98, axum 0.8, sqlx 0.9 (postgres, migrate, runtime-tokio, tls-rustls), jsonwebtoken 10, reqwest 0.13, uuid 1, chrono 0.4, tower-http 0.6 (trace), subtle 2, rand 0.10, rss 2 + atom_syndication 0.12 (feed validation), wiremock 0.6 + tower 0.5 (`util`) for tests. Postgres 18.

**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md` §3 (data model), §4 (auth/invites), §6 (API), §9 row "1 API MVP", §10 (testing).

## Global Constraints

- Never commit secrets; test keys in this plan are throwaway and only for tests.
- Route groups and auth exactly as spec §6: `/v1/*` Bearer Supabase JWT, `/internal/*` service token, `/admin/*` JWT + `is_admin`.
- Invite gate lives in the API: valid JWT without an `identities` row → `403 {"error":"invite_required"}`.
- Briefs store the V3 JSON verbatim in `payload` and upsert on `(feed_id, date)`.
- Notification fan-out is **off** in Phase 1 (`POST /internal/briefs` only stores).
- JWT verification fails closed; migrations run on startup and refuse to serve on failure (already true).
- Pipeline behaviour unchanged except the added dual-write; a failed API call never fails the daily run in Phase 1.
- Comments short and general. `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo test --workspace` green at every commit. Commit trailers per repo convention (Co-Authored-By + Claude-Session).
- Feed URL validation fetches the URL and parses RSS/Atom; no LLM in the request path.

## Prerequisites (Anton, outside this plan)

1. Create the Supabase project per `docs/runbooks/phase0-setup.md` §1 (there is none yet; the ref in `PULSE_ENV` is a placeholder). Update `PULSE_ENV` (`SUPABASE_JWKS_URL`, `SUPABASE_ISSUER`) with the real project ref, and add `ADMIN_EMAIL=anton.tsvetkov@gmail.com`.
2. Store the pipeline token in GCP Secret Manager with the same value as `PIPELINE_SERVICE_TOKEN` in `PULSE_ENV`: `gcloud secrets create pipeline-service-token --data-file=-` (Task 9 wires it into the daily job).

Tasks 1–8 need neither; they run against a local/CI Postgres and a test JWKS.

## Local test database

```bash
docker run -d --name pulse-pg -e POSTGRES_USER=pulse -e POSTGRES_PASSWORD=pulse -e POSTGRES_DB=pulse -p 5432:5432 postgres:18
export DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse
```

`#[sqlx::test]` creates a throwaway database per test from `DATABASE_URL` and applies `apps/pulse-api/migrations` automatically. CI's `api-it` job provides the same (Task 10).

## File structure

```
apps/pulse-api/
  Cargo.toml                     deps below
  migrations/0002_schema.sql     spec §3 tables
  src/main.rs                    config → pool → migrate → router → serve; `seed` subcommand
  src/config.rs                  Config::from_env
  src/error.rs                   ApiError → JSON responses
  src/state.rs                   AppState { pool, cfg, jwks }
  src/auth/mod.rs                pub use
  src/auth/claims.rs             Supabase Claims
  src/auth/jwks.rs               JwksCache: fetch/cache/verify
  src/auth/extractors.rs         Identity, AuthUser, AdminUser, ServiceToken
  src/db/{users,invites,feeds,briefs,feedback,devices,runs}.rs   sqlx queries
  src/routes/{mod,users,admin,feeds,briefs,devices,internal}.rs  handlers + Router
  src/feedcheck.rs               validate_feed_url
  src/seed.rs                    seed engineering feed + invite
  tests/common/mod.rs            test app, test tokens, JWKS mock
  tests/{auth,users,feeds,briefs,internal,devices}.rs
apps/daily-agent/src/api_client.rs   PulseApi dual-write client
docs/runbooks/phase1-setup.md
```

---

### Task 1: Config, error type, app state, router skeleton

**Files:**
- Modify: `apps/pulse-api/Cargo.toml`
- Create: `apps/pulse-api/src/config.rs`, `apps/pulse-api/src/error.rs`, `apps/pulse-api/src/state.rs`, `apps/pulse-api/src/routes/mod.rs`
- Modify: `apps/pulse-api/src/main.rs`

**Interfaces:**
- Produces: `Config::from_env() -> Result<Config, String>`; `ApiError` (variants below) implementing `IntoResponse`; `AppState { pool: PgPool, cfg: Arc<Config>, jwks: Arc<JwksCache> }` (jwks added in Task 3; until then a placeholder field is fine); `routes::router(state: AppState) -> Router`.

- [ ] **Step 1: Add dependencies**

```toml
[dependencies]
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
sqlx = { version = "0.9", features = ["runtime-tokio", "tls-rustls", "postgres", "migrate", "uuid", "chrono", "json"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
dotenvy = "0.15"
pulse-core = { path = "../../libs/pulse-core" }
jsonwebtoken = "10"
reqwest = { version = "0.13", features = ["json", "rustls-tls"], default-features = false }
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
tower-http = { version = "0.6", features = ["trace"] }
subtle = "2"
rand = "0.10"
rss = "2"
atom_syndication = "0.12"

[dev-dependencies]
tower = { version = "0.5", features = ["util"] }
wiremock = "0.6"
http-body-util = "0.1"
```

- [ ] **Step 2: Write the failing config test** in `apps/pulse-api/src/config.rs`

```rust
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub bind_addr: String,
    pub supabase_jwks_url: String,
    pub supabase_issuer: String,
    pub supabase_audience: String,
    pub pipeline_service_token: String,
    pub admin_email: Option<String>,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let vars: HashMap<String, String> = std::env::vars().collect();
        Self::from_map(&vars)
    }

    pub fn from_map(v: &HashMap<String, String>) -> Result<Self, String> {
        let req = |k: &str| v.get(k).cloned().filter(|s| !s.is_empty()).ok_or(format!("{k} is required"));
        Ok(Self {
            database_url: req("DATABASE_URL")?,
            bind_addr: v.get("BIND_ADDR").cloned().unwrap_or_else(|| "0.0.0.0:8080".into()),
            supabase_jwks_url: req("SUPABASE_JWKS_URL")?,
            supabase_issuer: req("SUPABASE_ISSUER")?,
            supabase_audience: v.get("SUPABASE_AUDIENCE").cloned().unwrap_or_else(|| "authenticated".into()),
            pipeline_service_token: req("PIPELINE_SERVICE_TOKEN")?,
            admin_email: v.get("ADMIN_EMAIL").cloned().map(|e| e.to_lowercase()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> HashMap<String, String> {
        [
            ("DATABASE_URL", "postgres://x"),
            ("SUPABASE_JWKS_URL", "https://p.supabase.co/auth/v1/.well-known/jwks.json"),
            ("SUPABASE_ISSUER", "https://p.supabase.co/auth/v1"),
            ("PIPELINE_SERVICE_TOKEN", "t"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    #[test]
    fn defaults_and_required() {
        let c = Config::from_map(&base()).unwrap();
        assert_eq!(c.bind_addr, "0.0.0.0:8080");
        assert_eq!(c.supabase_audience, "authenticated");
        assert!(c.admin_email.is_none());
        let mut m = base();
        m.remove("PIPELINE_SERVICE_TOKEN");
        assert_eq!(Config::from_map(&m).unwrap_err(), "PIPELINE_SERVICE_TOKEN is required");
    }

    #[test]
    fn admin_email_lowercased() {
        let mut m = base();
        m.insert("ADMIN_EMAIL".into(), "Anton@Example.com".into());
        assert_eq!(Config::from_map(&m).unwrap().admin_email.as_deref(), Some("anton@example.com"));
    }
}
```

- [ ] **Step 3: Run** `cargo test -p pulse-api config` → FAIL (module not wired). Add `mod config;` to `main.rs`, re-run → PASS.

- [ ] **Step 4: Error type** `apps/pulse-api/src/error.rs`

```rust
use axum::{http::StatusCode, response::{IntoResponse, Response}, Json};
use serde_json::json;

#[derive(Debug)]
pub enum ApiError {
    Unauthorized(&'static str),
    InviteRequired,
    Forbidden,
    NotFound(&'static str),
    Conflict(&'static str),
    BadRequest(String),
    Db(sqlx::Error),
    Internal(String),
}

impl ApiError {
    fn parts(&self) -> (StatusCode, &str, String) {
        match self {
            Self::Unauthorized(m) => (StatusCode::UNAUTHORIZED, "unauthorized", m.to_string()),
            Self::InviteRequired => (StatusCode::FORBIDDEN, "invite_required", "sign-up needs an invite code".into()),
            Self::Forbidden => (StatusCode::FORBIDDEN, "forbidden", "not allowed".into()),
            Self::NotFound(m) => (StatusCode::NOT_FOUND, "not_found", m.to_string()),
            Self::Conflict(m) => (StatusCode::CONFLICT, "conflict", m.to_string()),
            Self::BadRequest(m) => (StatusCode::UNPROCESSABLE_ENTITY, "bad_request", m.clone()),
            Self::Db(e) => (StatusCode::INTERNAL_SERVER_ERROR, "db_error", e.to_string()),
            Self::Internal(m) => (StatusCode::INTERNAL_SERVER_ERROR, "internal", m.clone()),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code, message) = self.parts();
        if status.is_server_error() {
            tracing::error!(code, %message, "request failed");
        }
        let body = if status.is_server_error() { json!({"error": code}) } else { json!({"error": code, "message": message}) };
        (status, Json(body)).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(e: sqlx::Error) -> Self {
        match e {
            sqlx::Error::RowNotFound => Self::NotFound("not found"),
            other => Self::Db(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn invite_required_is_403_with_code() {
        let resp = ApiError::InviteRequired.into_response();
        assert_eq!(resp.status(), StatusCode::FORBIDDEN);
        let body = axum::body::to_bytes(resp.into_body(), 1024).await.unwrap();
        assert_eq!(serde_json::from_slice::<serde_json::Value>(&body).unwrap()["error"], "invite_required");
    }

    #[tokio::test]
    async fn db_errors_hide_details() {
        let resp = ApiError::Internal("secret detail".into()).into_response();
        let body = axum::body::to_bytes(resp.into_body(), 1024).await.unwrap();
        assert!(!String::from_utf8_lossy(&body).contains("secret detail"));
    }
}
```

- [ ] **Step 5: State and router** `apps/pulse-api/src/state.rs` and `apps/pulse-api/src/routes/mod.rs`

```rust
// state.rs
use crate::{auth::jwks::JwksCache, config::Config};
use axum::extract::FromRef;
use sqlx::PgPool;
use std::sync::Arc;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub cfg: Arc<Config>,
    pub jwks: Arc<JwksCache>,
}

impl FromRef<AppState> for PgPool {
    fn from_ref(s: &AppState) -> PgPool { s.pool.clone() }
}
```

```rust
// routes/mod.rs
pub mod admin;
pub mod briefs;
pub mod devices;
pub mod feeds;
pub mod internal;
pub mod users;

use crate::{health, state::AppState};
use axum::{routing::get, Router};
use tower_http::trace::TraceLayer;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health::healthz))
        .merge(users::routes())
        .merge(admin::routes())
        .merge(feeds::routes())
        .merge(briefs::routes())
        .merge(devices::routes())
        .merge(internal::routes())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
```

Until Tasks 3–7 exist, create each `routes/*.rs` with `pub fn routes() -> Router<AppState> { Router::new() }` and `auth/jwks.rs` with an empty `pub struct JwksCache;` so the crate compiles; later tasks fill them in.

- [ ] **Step 6: main.rs**

```rust
mod auth;
mod config;
mod db;
mod error;
mod feedcheck;
mod health;
mod routes;
mod seed;
mod state;

use config::Config;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use tracing::info;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .json()
        .init();

    let cfg = Arc::new(Config::from_env()?);
    let pool = PgPoolOptions::new()
        .max_connections(8)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&cfg.database_url)
        .await?;
    sqlx::migrate!("./migrations").run(&pool).await?; // refuse to serve if migrations fail

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("seed") {
        return seed::run(&pool, &args[1..]).await.map_err(Into::into);
    }

    let jwks = Arc::new(auth::jwks::JwksCache::new(cfg.supabase_jwks_url.clone(), reqwest::Client::new()));
    let state = state::AppState { pool, cfg: cfg.clone(), jwks };
    let listener = tokio::net::TcpListener::bind(&cfg.bind_addr).await?;
    info!(bind = %cfg.bind_addr, "pulse-api listening");
    axum::serve(listener, routes::router(state)).await?;
    Ok(())
}
```

(`db`, `feedcheck`, `seed` modules: create empty files now; `seed::run` returns `Err("seed not implemented".into())` until Task 8.)

- [ ] **Step 7: Verify** `cargo build -p pulse-api && cargo test -p pulse-api` → all PASS. `/healthz` still works: run the binary with the env from "Local test database" plus the three Supabase/token vars set to dummy values and `curl localhost:8080/healthz`.

- [ ] **Step 8: Commit** `git commit -m "pulse-api: config, error type, app state, router skeleton"`

---

### Task 2: Schema migration and test harness

**Files:**
- Create: `apps/pulse-api/migrations/0002_schema.sql`, `apps/pulse-api/tests/common/mod.rs`, `apps/pulse-api/tests/schema.rs`

**Interfaces:**
- Produces: tables exactly as spec §3; `tests::common::{test_app, TestKeys, jwks_mock, token, TEST_KID}` used by every later test file (defined here in skeleton form, extended in Task 3).

- [ ] **Step 1: Migration** `0002_schema.sql`

```sql
CREATE TABLE users (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email        citext UNIQUE NOT NULL,
  display_name text,
  is_admin     boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE identities (
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  issuer   text NOT NULL,
  subject  text NOT NULL,
  PRIMARY KEY (issuer, subject)
);
CREATE INDEX identities_user_idx ON identities(user_id);
CREATE TABLE invites (
  code        text PRIMARY KEY,
  created_by  uuid REFERENCES users(id),
  max_uses    integer NOT NULL DEFAULT 1,
  used_count  integer NOT NULL DEFAULT 0,
  expires_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE feeds (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  description text,
  created_by  uuid REFERENCES users(id),
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE feed_topics (
  feed_id    uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  topic      text NOT NULL,
  added_by   uuid REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, topic)
);
CREATE TABLE feed_sources (
  feed_id    uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  url        text NOT NULL,
  kind       text NOT NULL CHECK (kind IN ('rss','atom','hackernews')),
  added_by   uuid REFERENCES users(id),
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, url)
);
CREATE TABLE memberships (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  feed_id      uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  role         text NOT NULL DEFAULT 'member' CHECK (role IN ('owner','member')),
  notify_email boolean NOT NULL DEFAULT true,
  notify_push  boolean NOT NULL DEFAULT true,
  joined_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, feed_id)
);
CREATE TABLE briefs (
  feed_id       uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date          date NOT NULL,
  format        text NOT NULL,
  payload       jsonb NOT NULL,
  article_url   text NOT NULL,
  article_title text NOT NULL,
  model         text,
  eval_score    real,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, date)
);
CREATE TABLE feedback (
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  feed_id    uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date       date NOT NULL,
  aspect     text NOT NULL,
  value      smallint NOT NULL CHECK (value IN (-1, 1)),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, feed_id, date, aspect)
);
CREATE TABLE device_tokens (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform    text NOT NULL CHECK (platform IN ('ios','android')),
  token       text UNIQUE NOT NULL,
  app_version text,
  is_active   boolean NOT NULL DEFAULT true,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE notifications_sent (
  feed_id  uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date     date NOT NULL,
  user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel  text NOT NULL,
  sent_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, date, user_id, channel)
);
CREATE TABLE runs (
  date          date NOT NULL,
  feed_id       uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  status        text NOT NULL CHECK (status IN ('ok','skipped','failed')),
  article_url   text,
  input_tokens  bigint NOT NULL DEFAULT 0,
  output_tokens bigint NOT NULL DEFAULT 0,
  est_cost_usd  double precision NOT NULL DEFAULT 0,
  error         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (date, feed_id)
);
```

- [ ] **Step 2: Schema test** `apps/pulse-api/tests/schema.rs`

```rust
use sqlx::PgPool;

#[sqlx::test]
async fn schema_has_all_tables(pool: PgPool) {
    let names: Vec<String> = sqlx::query_scalar(
        "select table_name::text from information_schema.tables where table_schema='public' and table_name <> '_sqlx_migrations' order by 1",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(
        names,
        ["briefs", "device_tokens", "feed_sources", "feed_topics", "feedback", "feeds", "identities", "invites", "memberships", "notifications_sent", "runs", "users"]
    );
}

#[sqlx::test]
async fn briefs_upsert_on_feed_and_date(pool: PgPool) {
    let feed: uuid::Uuid = sqlx::query_scalar("insert into feeds (slug, name) values ('t','T') returning id").fetch_one(&pool).await.unwrap();
    for title in ["a", "b"] {
        sqlx::query("insert into briefs (feed_id, date, format, payload, article_url, article_title) values ($1, '2026-09-16', 'insight-brief-v3', '{}', 'u', $2) on conflict (feed_id, date) do update set article_title = excluded.article_title")
            .bind(feed).bind(title).execute(&pool).await.unwrap();
    }
    let t: String = sqlx::query_scalar("select article_title from briefs").fetch_one(&pool).await.unwrap();
    assert_eq!(t, "b");
}
```

- [ ] **Step 3: Test harness skeleton** `apps/pulse-api/tests/common/mod.rs` (extended in Task 3)

```rust
#![allow(dead_code)]
use axum::{body::Body, http::{Request, Response}, Router};
use pulse_api_test_support::*; // see note below
```

Note: integration tests can't import a binary crate's private modules. To keep handlers testable, split the crate: `apps/pulse-api/src/lib.rs` exposes `pub mod auth; pub mod config; pub mod db; pub mod error; pub mod feedcheck; pub mod health; pub mod routes; pub mod seed; pub mod state;` and `main.rs` becomes a thin binary calling `pulse_api::run().await` (move the body of `main` into `pub async fn run() -> Result<(), Box<dyn std::error::Error>>` in `lib.rs`). Do that in this step; then `tests/common/mod.rs` is:

```rust
#![allow(dead_code)]
use axum::{body::Body, http::{header, Method, Request, Response}, Router};
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

pub async fn send(app: &Router, method: Method, path: &str, bearer: Option<&str>, body: Option<serde_json::Value>) -> (u16, serde_json::Value) {
    let mut req = Request::builder().method(method).uri(path);
    if let Some(t) = bearer { req = req.header(header::AUTHORIZATION, format!("Bearer {t}")); }
    let req = match body {
        Some(b) => req.header(header::CONTENT_TYPE, "application/json").body(Body::from(b.to_string())).unwrap(),
        None => req.body(Body::empty()).unwrap(),
    };
    let resp: Response<Body> = app.clone().oneshot(req).await.unwrap();
    let status = resp.status().as_u16();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let json = if bytes.is_empty() { serde_json::Value::Null } else { serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::String(String::from_utf8_lossy(&bytes).into())) };
    (status, json)
}
```

- [ ] **Step 4: Run** `cargo test -p pulse-api --test schema` → PASS (requires `DATABASE_URL`).

- [ ] **Step 5: Commit** `git commit -m "pulse-api: schema migration, lib/bin split, test harness"`

---

### Task 3: JWT verification, JWKS cache, extractors

**Files:**
- Create: `apps/pulse-api/src/auth/mod.rs`, `claims.rs`, `jwks.rs`, `extractors.rs`, `apps/pulse-api/src/db/users.rs`, `apps/pulse-api/tests/auth.rs`
- Modify: `apps/pulse-api/tests/common/mod.rs`

**Interfaces:**
- Produces: `Claims { sub: String, email: Option<String>, email_verified: bool, iss: String }`; `JwksCache::new(url, client)`, `JwksCache::verify(&self, token, issuer, audience) -> Result<Claims, ApiError>`; extractors `Identity(Claims)` (valid JWT), `AuthUser { id: Uuid, email: String, is_admin: bool, claims: Claims }` (registered user; `403 invite_required` otherwise), `AdminUser(AuthUser)`, `ServiceToken`; `db::users::{find_by_identity, find_by_email, link_identity}`.

- [ ] **Step 1: Claims** `auth/claims.rs`

```rust
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub iss: String,
    pub exp: usize,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub user_metadata: Option<UserMetadata>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct UserMetadata {
    #[serde(default)]
    pub email_verified: bool,
}

impl Claims {
    pub fn email_verified(&self) -> bool {
        self.user_metadata.as_ref().map(|m| m.email_verified).unwrap_or(false)
    }
    pub fn email_lower(&self) -> Option<String> {
        self.email.as_ref().map(|e| e.trim().to_lowercase())
    }
}
```

- [ ] **Step 2: JWKS cache** `auth/jwks.rs`

```rust
use crate::{auth::claims::Claims, error::ApiError};
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use std::{collections::HashMap, sync::Arc, time::{Duration, Instant}};
use tokio::sync::RwLock;

pub struct JwksCache {
    url: String,
    http: reqwest::Client,
    keys: RwLock<HashMap<String, (DecodingKey, Algorithm)>>,
    last_fetch: RwLock<Option<Instant>>,
}

const MIN_REFRESH: Duration = Duration::from_secs(60);

impl JwksCache {
    pub fn new(url: String, http: reqwest::Client) -> Self {
        Self { url, http, keys: RwLock::new(HashMap::new()), last_fetch: RwLock::new(None) }
    }

    async fn refresh(&self) -> Result<(), ApiError> {
        let mut last = self.last_fetch.write().await;
        if last.map(|t| t.elapsed() < MIN_REFRESH).unwrap_or(false) {
            return Ok(());
        }
        let set: JwkSet = self.http.get(&self.url).send().await
            .and_then(|r| r.error_for_status())
            .map_err(|e| ApiError::Internal(format!("jwks fetch: {e}")))?
            .json().await.map_err(|e| ApiError::Internal(format!("jwks parse: {e}")))?;
        let mut keys = HashMap::new();
        for jwk in set.keys {
            let Some(kid) = jwk.common.key_id.clone() else { continue };
            let alg = match jwk.common.key_algorithm {
                Some(jsonwebtoken::jwk::KeyAlgorithm::ES256) => Algorithm::ES256,
                Some(jsonwebtoken::jwk::KeyAlgorithm::RS256) => Algorithm::RS256,
                _ => continue,
            };
            if let Ok(key) = DecodingKey::from_jwk(&jwk) { keys.insert(kid, (key, alg)); }
        }
        *self.keys.write().await = keys;
        *last = Some(Instant::now());
        Ok(())
    }

    async fn key_for(&self, kid: &str) -> Result<(DecodingKey, Algorithm), ApiError> {
        if let Some(k) = self.keys.read().await.get(kid) { return Ok(k.clone()); }
        self.refresh().await?;
        self.keys.read().await.get(kid).cloned().ok_or(ApiError::Unauthorized("unknown key id"))
    }

    pub async fn verify(&self, token: &str, issuer: &str, audience: &str) -> Result<Claims, ApiError> {
        let header = decode_header(token).map_err(|_| ApiError::Unauthorized("malformed token"))?;
        let kid = header.kid.ok_or(ApiError::Unauthorized("token has no kid"))?;
        let (key, alg) = self.key_for(&kid).await?;
        let mut v = Validation::new(alg);
        v.set_issuer(&[issuer]);
        v.set_audience(&[audience]);
        v.validate_exp = true;
        decode::<Claims>(token, &key, &v).map(|d| d.claims).map_err(|_| ApiError::Unauthorized("invalid token"))
    }
}

pub type SharedJwks = Arc<JwksCache>;
```

- [ ] **Step 3: User lookups** `db/users.rs`

```rust
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    pub display_name: Option<String>,
    pub is_admin: bool,
}

pub async fn find_by_identity(pool: &PgPool, issuer: &str, subject: &str) -> sqlx::Result<Option<User>> {
    sqlx::query_as("select u.id, u.email::text as email, u.display_name, u.is_admin from users u join identities i on i.user_id = u.id where i.issuer = $1 and i.subject = $2")
        .bind(issuer).bind(subject).fetch_optional(pool).await
}

pub async fn find_by_email(pool: &PgPool, email: &str) -> sqlx::Result<Option<User>> {
    sqlx::query_as("select id, email::text as email, display_name, is_admin from users where email = $1")
        .bind(email).fetch_optional(pool).await
}

pub async fn link_identity(pool: &PgPool, user_id: Uuid, issuer: &str, subject: &str) -> sqlx::Result<()> {
    sqlx::query("insert into identities (user_id, issuer, subject) values ($1, $2, $3) on conflict do nothing")
        .bind(user_id).bind(issuer).bind(subject).execute(pool).await.map(|_| ())
}

pub async fn insert_user(tx: &mut Transaction<'_, Postgres>, email: &str, is_admin: bool) -> sqlx::Result<User> {
    sqlx::query_as("insert into users (email, is_admin) values ($1, $2) returning id, email::text as email, display_name, is_admin")
        .bind(email).bind(is_admin).fetch_one(&mut **tx).await
}

pub async fn insert_identity(tx: &mut Transaction<'_, Postgres>, user_id: Uuid, issuer: &str, subject: &str) -> sqlx::Result<()> {
    sqlx::query("insert into identities (user_id, issuer, subject) values ($1, $2, $3)")
        .bind(user_id).bind(issuer).bind(subject).execute(&mut **tx).await.map(|_| ())
}
```

- [ ] **Step 4: Extractors** `auth/extractors.rs`

```rust
use crate::{auth::claims::Claims, db::users::{self, User}, error::ApiError, state::AppState};
use axum::{extract::FromRequestParts, http::{header, request::Parts}};
use subtle::ConstantTimeEq;
use uuid::Uuid;

fn bearer(parts: &Parts) -> Result<&str, ApiError> {
    parts.headers.get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|t| !t.is_empty())
        .ok_or(ApiError::Unauthorized("missing bearer token"))
}

/// A verified Supabase JWT; the caller may not be registered yet.
pub struct Identity(pub Claims);

impl FromRequestParts<AppState> for Identity {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer(parts)?;
        let claims = state.jwks.verify(token, &state.cfg.supabase_issuer, &state.cfg.supabase_audience).await?;
        Ok(Identity(claims))
    }
}

/// A registered user. Links a new identity when the verified email already has an account.
pub struct AuthUser {
    pub id: Uuid,
    pub email: String,
    pub is_admin: bool,
    pub claims: Claims,
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let Identity(claims) = Identity::from_request_parts(parts, state).await?;
        let user: User = match users::find_by_identity(&state.pool, &claims.iss, &claims.sub).await? {
            Some(u) => u,
            None => {
                let linked = match claims.email_lower() {
                    Some(email) if claims.email_verified() => users::find_by_email(&state.pool, &email).await?,
                    _ => None,
                };
                let Some(u) = linked else { return Err(ApiError::InviteRequired) };
                users::link_identity(&state.pool, u.id, &claims.iss, &claims.sub).await?;
                u
            }
        };
        Ok(AuthUser { id: user.id, email: user.email, is_admin: user.is_admin, claims })
    }
}

pub struct AdminUser(pub AuthUser);

impl FromRequestParts<AppState> for AdminUser {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let u = AuthUser::from_request_parts(parts, state).await?;
        if u.is_admin { Ok(AdminUser(u)) } else { Err(ApiError::Forbidden) }
    }
}

/// `/internal/*` caller: static pipeline token, constant-time compared.
pub struct ServiceToken;

impl FromRequestParts<AppState> for ServiceToken {
    type Rejection = ApiError;
    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        let token = bearer(parts)?;
        let expected = state.cfg.pipeline_service_token.as_bytes();
        if token.len() == expected.len() && token.as_bytes().ct_eq(expected).into() {
            Ok(ServiceToken)
        } else {
            Err(ApiError::Unauthorized("bad service token"))
        }
    }
}
```

`auth/mod.rs`: `pub mod claims; pub mod extractors; pub mod jwks;`. `db/mod.rs`: `pub mod users;` (more added later).

- [ ] **Step 5: Test support for tokens** — extend `tests/common/mod.rs`

```rust
use jsonwebtoken::{encode, EncodingKey, Header, Algorithm};
use wiremock::{matchers::{method, path}, Mock, MockServer, ResponseTemplate};

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
    Mock::given(method("GET")).and(path("/jwks")).respond_with(ResponseTemplate::new(200).set_body_json(jwks_json())).mount(&server).await;
    let url = format!("{}/jwks", server.uri());
    (server, url)
}

pub struct TokenOpts { pub sub: String, pub email: Option<String>, pub verified: bool, pub exp_offset_secs: i64, pub kid: String, pub aud: String, pub iss: String }

impl Default for TokenOpts {
    fn default() -> Self {
        Self { sub: uuid::Uuid::new_v4().to_string(), email: Some("user@example.com".into()), verified: true, exp_offset_secs: 3600, kid: TEST_KID.into(), aud: "authenticated".into(), iss: ISSUER.into() }
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
    encode(&header, &claims, &EncodingKey::from_ec_pem(TEST_PRIVATE_KEY_PEM.as_bytes()).unwrap()).unwrap()
}

pub fn user_token(sub: &str, email: &str) -> String {
    token(TokenOpts { sub: sub.into(), email: Some(email.into()), ..Default::default() })
}

/// Registers a user directly in the DB (bypassing invites) and returns (user_id, bearer token).
pub async fn registered_user(pool: &PgPool, email: &str, is_admin: bool) -> (uuid::Uuid, String) {
    let sub = uuid::Uuid::new_v4().to_string();
    let id: uuid::Uuid = sqlx::query_scalar("insert into users (email, is_admin) values ($1, $2) returning id").bind(email).bind(is_admin).fetch_one(pool).await.unwrap();
    sqlx::query("insert into identities (user_id, issuer, subject) values ($1, $2, $3)").bind(id).bind(ISSUER).bind(&sub).execute(pool).await.unwrap();
    (id, user_token(&sub, email))
}
```

Add `jsonwebtoken`, `serde_json`, `chrono`, `uuid`, `wiremock`, `reqwest`, `sqlx` to dev-dependencies as needed (most are already regular deps).

- [ ] **Step 6: Auth tests** `tests/auth.rs`. `GET /v1/me` (Task 4) is the probe; until Task 4 exists, add a temporary route in `routes/users.rs`: `GET /v1/me` returning `Json(json!({"id": user.id, "email": user.email, "is_admin": user.is_admin}))` for an `AuthUser` — Task 4 keeps it.

```rust
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
    let t = token(TokenOpts { exp_offset_secs: -10, ..Default::default() });
    let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 401);
}

#[sqlx::test]
async fn wrong_issuer_or_audience_is_401(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    for t in [token(TokenOpts { iss: "https://other".into(), ..Default::default() }), token(TokenOpts { aud: "anon".into(), ..Default::default() })] {
        let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
        assert_eq!(status, 401);
    }
}

#[sqlx::test]
async fn unknown_kid_is_401_after_refresh(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let t = token(TokenOpts { kid: "nope".into(), ..Default::default() });
    let (status, body) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 401);
    assert_eq!(body["message"], "unknown key id");
}

#[sqlx::test]
async fn valid_token_without_account_is_invite_required(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::GET, "/v1/me", Some(&user_token("sub-1", "new@example.com")), None).await;
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
    let n: i64 = sqlx::query_scalar("select count(*) from identities where user_id = $1").bind(id).fetch_one(&pool).await.unwrap();
    assert_eq!(n, 2);
}

#[sqlx::test]
async fn unverified_email_does_not_link(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    registered_user(&pool, "nolink@example.com", false).await;
    let app = app(pool, &url);
    let t = token(TokenOpts { sub: "x".into(), email: Some("nolink@example.com".into()), verified: false, ..Default::default() });
    let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 403);
}

#[sqlx::test]
async fn internal_requires_service_token(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let app = app(pool, &url);
    let (s1, _) = send(&app, Method::GET, "/internal/feeds", None, None).await;
    let (s2, _) = send(&app, Method::GET, "/internal/feeds", Some("wrong"), None).await;
    let (s3, _) = send(&app, Method::GET, "/internal/feeds", Some(SERVICE_TOKEN), None).await;
    assert_eq!((s1, s2, s3), (401, 401, 200));
}
```

For the last test, add a temporary `GET /internal/feeds` in `routes/internal.rs` returning `Json(Vec::<pulse_core::Feed>::new())` behind `ServiceToken`; Task 6 replaces the body.

- [ ] **Step 7: Run** `cargo test -p pulse-api --test auth` → PASS. Also `cargo clippy --workspace --all-targets -- -D warnings`.

- [ ] **Step 8: Commit** `git commit -m "pulse-api: Supabase JWT verification via JWKS, invite gate, service token"`

---

### Task 4: Users, invites, admin invite minting

**Files:**
- Create: `apps/pulse-api/src/db/invites.rs`, `apps/pulse-api/tests/users.rs`
- Modify: `apps/pulse-api/src/routes/users.rs`, `apps/pulse-api/src/routes/admin.rs`, `apps/pulse-api/src/db/mod.rs`

**Interfaces:**
- Produces: `POST /v1/users {invite_code}` → 201 `{id,email,is_admin}` (200 if already registered); `GET /v1/me`; `POST /admin/invites {max_uses?, expires_in_days?}` → 201 `{code, max_uses, expires_at}`; `db::invites::{consume, create}`.

- [ ] **Step 1: Failing tests** `tests/users.rs`

```rust
mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

async fn invite(pool: &PgPool, code: &str, max_uses: i32, expired: bool) {
    let exp = if expired { "now() - interval '1 day'" } else { "now() + interval '30 days'" };
    sqlx::query(&format!("insert into invites (code, max_uses, expires_at) values ($1, $2, {exp})")).bind(code).bind(max_uses).execute(pool).await.unwrap();
}

#[sqlx::test]
async fn signup_with_invite_creates_user_and_identity(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "FRIENDS", 2, false).await;
    let app = app(pool.clone(), &url);
    let t = user_token("sub-a", "a@example.com");
    let (status, body) = send(&app, Method::POST, "/v1/users", Some(&t), Some(json!({"invite_code": "FRIENDS"}))).await;
    assert_eq!(status, 201);
    assert_eq!(body["email"], "a@example.com");
    let used: i32 = sqlx::query_scalar("select used_count from invites where code = 'FRIENDS'").fetch_one(&pool).await.unwrap();
    assert_eq!(used, 1);
    let (status, _) = send(&app, Method::GET, "/v1/me", Some(&t), None).await;
    assert_eq!(status, 200);
}

#[sqlx::test]
async fn signup_is_idempotent_for_registered_user(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "b@example.com", false).await;
    let app = app(pool, &url);
    let (status, _) = send(&app, Method::POST, "/v1/users", Some(&t), Some(json!({"invite_code": "whatever"}))).await;
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
        let (status, body) = send(&app, Method::POST, "/v1/users", Some(&t), Some(json!({"invite_code": code}))).await;
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
    let (status, body) = send(&app, Method::POST, "/v1/users", Some(&t), Some(json!({"invite_code": "BOOT"}))).await;
    assert_eq!(status, 201);
    assert_eq!(body["is_admin"], true);
    let (status, body) = send(&app, Method::POST, "/admin/invites", Some(&t), Some(json!({"max_uses": 5, "expires_in_days": 7}))).await;
    assert_eq!(status, 201);
    assert_eq!(body["code"].as_str().unwrap().len(), 12);
    assert_eq!(body["max_uses"], 5);
}

#[sqlx::test]
async fn non_admin_cannot_mint_invites(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "plain@example.com", false).await;
    let app = app(pool, &url);
    let (status, _) = send(&app, Method::POST, "/admin/invites", Some(&t), Some(json!({}))).await;
    assert_eq!(status, 403);
}

#[sqlx::test]
async fn signup_needs_email_in_token(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    invite(&pool, "X", 1, false).await;
    let app = app(pool, &url);
    let t = token(TokenOpts { email: None, ..Default::default() });
    let (status, _) = send(&app, Method::POST, "/v1/users", Some(&t), Some(json!({"invite_code": "X"}))).await;
    assert_eq!(status, 422);
}
```

- [ ] **Step 2: Run** `cargo test -p pulse-api --test users` → FAIL (404s).

- [ ] **Step 3: Invites db** `db/invites.rs`

```rust
use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct Invite { pub code: String, pub max_uses: i32, pub used_count: i32, pub expires_at: Option<DateTime<Utc>> }

/// Atomically consumes one use; None when the code is missing, expired or exhausted.
pub async fn consume(tx: &mut Transaction<'_, Postgres>, code: &str) -> sqlx::Result<Option<Invite>> {
    sqlx::query_as("update invites set used_count = used_count + 1 where code = $1 and used_count < max_uses and (expires_at is null or expires_at > now()) returning code, max_uses, used_count, expires_at")
        .bind(code).fetch_optional(&mut **tx).await
}

pub fn new_code() -> String {
    use rand::RngExt;
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();
    (0..12).map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char).collect()
}

pub async fn create(pool: &PgPool, created_by: Uuid, max_uses: i32, expires_at: Option<DateTime<Utc>>) -> sqlx::Result<Invite> {
    sqlx::query_as("insert into invites (code, created_by, max_uses, expires_at) values ($1, $2, $3, $4) returning code, max_uses, used_count, expires_at")
        .bind(new_code()).bind(created_by).bind(max_uses).bind(expires_at).fetch_one(pool).await
}
```

(If `rand::RngExt`/`rand::rng()` names differ in the resolved rand 0.10, use the crate's documented equivalents; the test `code.len() == 12` pins behaviour.)

- [ ] **Step 4: Routes** `routes/users.rs`

```rust
use crate::{auth::extractors::{AuthUser, Identity}, db::{invites, users}, error::ApiError, state::AppState};
use axum::{extract::State, http::StatusCode, routing::{get, post}, Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new().route("/v1/users", post(signup)).route("/v1/me", get(me))
}

#[derive(Deserialize)]
struct Signup { invite_code: String }

async fn signup(State(state): State<AppState>, Identity(claims): Identity, Json(body): Json<Signup>) -> Result<(StatusCode, Json<Value>), ApiError> {
    if let Some(u) = users::find_by_identity(&state.pool, &claims.iss, &claims.sub).await? {
        return Ok((StatusCode::OK, Json(user_json(&u))));
    }
    let email = claims.email_lower().ok_or_else(|| ApiError::BadRequest("token has no email".into()))?;
    let mut tx = state.pool.begin().await?;
    invites::consume(&mut tx, body.invite_code.trim()).await?.ok_or_else(|| ApiError::BadRequest("invite code is invalid, expired or used up".into()))?;
    let is_admin = state.cfg.admin_email.as_deref() == Some(email.as_str());
    let user = match users::find_by_email(&state.pool, &email).await? {
        Some(existing) => existing,
        None => users::insert_user(&mut tx, &email, is_admin).await?,
    };
    users::insert_identity(&mut tx, user.id, &claims.iss, &claims.sub).await?;
    tx.commit().await?;
    Ok((StatusCode::CREATED, Json(user_json(&user))))
}

async fn me(user: AuthUser) -> Json<Value> {
    Json(json!({"id": user.id, "email": user.email, "is_admin": user.is_admin}))
}

pub fn user_json(u: &users::User) -> Value {
    json!({"id": u.id, "email": u.email, "display_name": u.display_name, "is_admin": u.is_admin})
}
```

`routes/admin.rs`:

```rust
use crate::{auth::extractors::AdminUser, db::invites, error::ApiError, state::AppState};
use axum::{extract::State, http::StatusCode, routing::post, Json, Router};
use serde::Deserialize;

pub fn routes() -> Router<AppState> { Router::new().route("/admin/invites", post(mint)) }

#[derive(Deserialize, Default)]
struct Mint { max_uses: Option<i32>, expires_in_days: Option<i64> }

async fn mint(State(state): State<AppState>, AdminUser(admin): AdminUser, body: Option<Json<Mint>>) -> Result<(StatusCode, Json<invites::Invite>), ApiError> {
    let m = body.map(|b| b.0).unwrap_or_default();
    let expires = m.expires_in_days.map(|d| chrono::Utc::now() + chrono::Duration::days(d));
    let inv = invites::create(&state.pool, admin.id, m.max_uses.unwrap_or(1).max(1), expires).await?;
    Ok((StatusCode::CREATED, Json(inv)))
}
```

- [ ] **Step 5: Run** `cargo test -p pulse-api --test users --test auth` → PASS.

- [ ] **Step 6: Commit** `git commit -m "pulse-api: sign-up with invite codes, /v1/me, admin invite minting"`

---

### Task 5: Feeds, memberships, topics, sources

**Files:**
- Create: `apps/pulse-api/src/db/feeds.rs`, `apps/pulse-api/src/feedcheck.rs`, `apps/pulse-api/tests/feeds.rs`
- Modify: `apps/pulse-api/src/routes/feeds.rs`, `apps/pulse-api/src/db/mod.rs`

**Interfaces:**
- Produces: `GET /v1/feeds` → `[{id, slug, name, description, is_active, member: bool, role: "owner"|"member"|null, topics: [..], sources: [{url, kind}]}]`; `POST /v1/feeds {slug, name, description?}` → 201 (creator gets `owner` membership); `POST /v1/feeds/{id}/membership {notify_email?, notify_push?}` → 200 (upsert); `DELETE /v1/feeds/{id}/membership` → 204; `POST /v1/feeds/{id}/topics {topic}` → 201; `DELETE /v1/feeds/{id}/topics/{topic}` → 204; `POST /v1/feeds/{id}/sources {url}` → 201 `{url, kind}` after validation; `DELETE /v1/feeds/{id}/sources?url=` → 204. Members can edit topics/sources; anyone signed in can join. `feedcheck::validate_feed_url(client, url) -> Result<pulse_core::SourceKind, String>`; `db::feeds::{list_for_user, get, create, upsert_membership, delete_membership, add_topic, remove_topic, add_source, remove_source, is_member, FeedRow}`.

- [ ] **Step 1: Failing tests** `tests/feeds.rs`

```rust
mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;
use wiremock::{matchers::{method, path}, Mock, ResponseTemplate};

const RSS: &str = r#"<?xml version="1.0"?><rss version="2.0"><channel><title>T</title><link>http://x</link><description>d</description><item><title>a</title><link>http://x/a</link></item></channel></rss>"#;

#[sqlx::test]
async fn create_join_and_list(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, owner) = registered_user(&pool, "o@example.com", false).await;
    let (_, other) = registered_user(&pool, "m@example.com", false).await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::POST, "/v1/feeds", Some(&owner), Some(json!({"slug": "rust", "name": "Rust", "description": "systems"}))).await;
    assert_eq!(status, 201);
    let id = body["id"].as_str().unwrap().to_string();
    let (status, body) = send(&app, Method::GET, "/v1/feeds", Some(&other), None).await;
    assert_eq!(status, 200);
    assert_eq!(body[0]["member"], false);
    let (status, _) = send(&app, Method::POST, &format!("/v1/feeds/{id}/membership"), Some(&other), Some(json!({"notify_push": false}))).await;
    assert_eq!(status, 200);
    let (_, body) = send(&app, Method::GET, "/v1/feeds", Some(&other), None).await;
    assert_eq!(body[0]["member"], true);
    assert_eq!(body[0]["role"], "member");
    let (_, body) = send(&app, Method::GET, "/v1/feeds", Some(&owner), None).await;
    assert_eq!(body[0]["role"], "owner");
    let (status, _) = send(&app, Method::DELETE, &format!("/v1/feeds/{id}/membership"), Some(&other), None).await;
    assert_eq!(status, 204);
}

#[sqlx::test]
async fn duplicate_slug_is_409(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (_, t) = registered_user(&pool, "o@example.com", false).await;
    let app = app(pool, &url);
    send(&app, Method::POST, "/v1/feeds", Some(&t), Some(json!({"slug": "x", "name": "X"}))).await;
    let (status, _) = send(&app, Method::POST, "/v1/feeds", Some(&t), Some(json!({"slug": "x", "name": "X2"}))).await;
    assert_eq!(status, 409);
}

#[sqlx::test]
async fn topics_and_sources_require_membership(pool: PgPool) {
    let (server, url) = jwks_mock().await;
    Mock::given(method("GET")).and(path("/feed.xml")).respond_with(ResponseTemplate::new(200).set_body_string(RSS)).mount(&server).await;
    Mock::given(method("GET")).and(path("/page.html")).respond_with(ResponseTemplate::new(200).set_body_string("<html>no feed</html>")).mount(&server).await;
    let (_, owner) = registered_user(&pool, "o@example.com", false).await;
    let (_, stranger) = registered_user(&pool, "s@example.com", false).await;
    let app = app(pool, &url);
    let (_, body) = send(&app, Method::POST, "/v1/feeds", Some(&owner), Some(json!({"slug": "f", "name": "F"}))).await;
    let id = body["id"].as_str().unwrap().to_string();
    let (status, _) = send(&app, Method::POST, &format!("/v1/feeds/{id}/topics"), Some(&stranger), Some(json!({"topic": "wasm"}))).await;
    assert_eq!(status, 403);
    let (status, _) = send(&app, Method::POST, &format!("/v1/feeds/{id}/topics"), Some(&owner), Some(json!({"topic": " WASM "}))).await;
    assert_eq!(status, 201);
    let feed_url = format!("{}/feed.xml", server.uri());
    let (status, body) = send(&app, Method::POST, &format!("/v1/feeds/{id}/sources"), Some(&owner), Some(json!({"url": feed_url}))).await;
    assert_eq!(status, 201);
    assert_eq!(body["kind"], "rss");
    let (status, body) = send(&app, Method::POST, &format!("/v1/feeds/{id}/sources"), Some(&owner), Some(json!({"url": format!("{}/page.html", server.uri())}))).await;
    assert_eq!(status, 422);
    assert!(body["message"].as_str().unwrap().contains("not an RSS or Atom feed"));
    let (_, body) = send(&app, Method::GET, "/v1/feeds", Some(&owner), None).await;
    assert_eq!(body[0]["topics"], json!(["wasm"]));
    assert_eq!(body[0]["sources"][0]["kind"], "rss");
    let (status, _) = send(&app, Method::DELETE, &format!("/v1/feeds/{id}/topics/wasm"), Some(&owner), None).await;
    assert_eq!(status, 204);
    let (status, _) = send(&app, Method::DELETE, &format!("/v1/feeds/{id}/sources?url={}", urlencoding::encode(&feed_url)), Some(&owner), None).await;
    assert_eq!(status, 204);
}
```

Add `urlencoding = "2"` to dev-dependencies.

- [ ] **Step 2: Run** → FAIL. 

- [ ] **Step 3: Feed validation** `feedcheck.rs`

```rust
use pulse_core::SourceKind;
use std::time::Duration;

/// Fetches the URL and checks it parses as RSS or Atom. No LLM here.
pub async fn validate_feed_url(client: &reqwest::Client, url: &str) -> Result<SourceKind, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "invalid URL".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") { return Err("URL must be http(s)".into()); }
    let body = client.get(parsed).timeout(Duration::from_secs(10)).send().await
        .and_then(|r| r.error_for_status()).map_err(|e| format!("fetch failed: {e}"))?
        .bytes().await.map_err(|e| format!("read failed: {e}"))?;
    if rss::Channel::read_from(&body[..]).is_ok() { return Ok(SourceKind::Rss); }
    if atom_syndication::Feed::read_from(&body[..]).is_ok() { return Ok(SourceKind::Atom); }
    Err("URL is not an RSS or Atom feed".into())
}

pub fn kind_str(k: SourceKind) -> &'static str {
    match k { SourceKind::Rss => "rss", SourceKind::Atom => "atom", SourceKind::HackerNews => "hackernews" }
}
```

- [ ] **Step 4: Feeds db** `db/feeds.rs`

```rust
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
pub struct FeedRow { pub id: Uuid, pub slug: String, pub name: String, pub description: Option<String>, pub is_active: bool, pub role: Option<String> }

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct SourceRow { pub url: String, pub kind: String }

pub async fn list_for_user(pool: &PgPool, user_id: Uuid) -> sqlx::Result<Vec<FeedRow>> {
    sqlx::query_as("select f.id, f.slug, f.name, f.description, f.is_active, m.role from feeds f left join memberships m on m.feed_id = f.id and m.user_id = $1 where f.is_active order by f.slug")
        .bind(user_id).fetch_all(pool).await
}

pub async fn topics(pool: &PgPool, feed_id: Uuid) -> sqlx::Result<Vec<String>> {
    sqlx::query_scalar("select topic from feed_topics where feed_id = $1 order by topic").bind(feed_id).fetch_all(pool).await
}

pub async fn sources(pool: &PgPool, feed_id: Uuid) -> sqlx::Result<Vec<SourceRow>> {
    sqlx::query_as("select url, kind from feed_sources where feed_id = $1 and is_active order by url").bind(feed_id).fetch_all(pool).await
}

pub async fn create(pool: &PgPool, user_id: Uuid, slug: &str, name: &str, description: Option<&str>) -> sqlx::Result<Uuid> {
    let mut tx = pool.begin().await?;
    let id: Uuid = sqlx::query_scalar("insert into feeds (slug, name, description, created_by) values ($1, $2, $3, $4) returning id")
        .bind(slug).bind(name).bind(description).bind(user_id).fetch_one(&mut *tx).await?;
    sqlx::query("insert into memberships (user_id, feed_id, role) values ($1, $2, 'owner')").bind(user_id).bind(id).execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(id)
}

pub async fn exists(pool: &PgPool, feed_id: Uuid) -> sqlx::Result<bool> {
    sqlx::query_scalar("select exists(select 1 from feeds where id = $1 and is_active)").bind(feed_id).fetch_one(pool).await
}

pub async fn is_member(pool: &PgPool, user_id: Uuid, feed_id: Uuid) -> sqlx::Result<bool> {
    sqlx::query_scalar("select exists(select 1 from memberships where user_id = $1 and feed_id = $2)").bind(user_id).bind(feed_id).fetch_one(pool).await
}

pub async fn upsert_membership(pool: &PgPool, user_id: Uuid, feed_id: Uuid, notify_email: Option<bool>, notify_push: Option<bool>) -> sqlx::Result<()> {
    sqlx::query("insert into memberships (user_id, feed_id, notify_email, notify_push) values ($1, $2, coalesce($3, true), coalesce($4, true)) on conflict (user_id, feed_id) do update set notify_email = coalesce($3, memberships.notify_email), notify_push = coalesce($4, memberships.notify_push)")
        .bind(user_id).bind(feed_id).bind(notify_email).bind(notify_push).execute(pool).await.map(|_| ())
}

pub async fn delete_membership(pool: &PgPool, user_id: Uuid, feed_id: Uuid) -> sqlx::Result<()> {
    sqlx::query("delete from memberships where user_id = $1 and feed_id = $2").bind(user_id).bind(feed_id).execute(pool).await.map(|_| ())
}

pub async fn add_topic(pool: &PgPool, feed_id: Uuid, topic: &str, user_id: Uuid) -> sqlx::Result<()> {
    sqlx::query("insert into feed_topics (feed_id, topic, added_by) values ($1, $2, $3) on conflict do nothing").bind(feed_id).bind(topic).bind(user_id).execute(pool).await.map(|_| ())
}

pub async fn remove_topic(pool: &PgPool, feed_id: Uuid, topic: &str) -> sqlx::Result<()> {
    sqlx::query("delete from feed_topics where feed_id = $1 and topic = $2").bind(feed_id).bind(topic).execute(pool).await.map(|_| ())
}

pub async fn add_source(pool: &PgPool, feed_id: Uuid, url: &str, kind: &str, user_id: Uuid) -> sqlx::Result<()> {
    sqlx::query("insert into feed_sources (feed_id, url, kind, added_by) values ($1, $2, $3, $4) on conflict (feed_id, url) do update set is_active = true, kind = excluded.kind").bind(feed_id).bind(url).bind(kind).bind(user_id).execute(pool).await.map(|_| ())
}

pub async fn remove_source(pool: &PgPool, feed_id: Uuid, url: &str) -> sqlx::Result<()> {
    sqlx::query("update feed_sources set is_active = false where feed_id = $1 and url = $2").bind(feed_id).bind(url).execute(pool).await.map(|_| ())
}
```

- [ ] **Step 5: Routes** `routes/feeds.rs`

```rust
use crate::{auth::extractors::AuthUser, db::feeds, error::ApiError, feedcheck, state::AppState};
use axum::{extract::{Path, Query, State}, http::StatusCode, routing::{get, post}, Json, Router};
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/feeds", get(list).post(create))
        .route("/v1/feeds/{id}/membership", post(join).delete(leave))
        .route("/v1/feeds/{id}/topics", post(add_topic))
        .route("/v1/feeds/{id}/topics/{topic}", axum::routing::delete(remove_topic))
        .route("/v1/feeds/{id}/sources", post(add_source).delete(remove_source))
}

async fn list(State(s): State<AppState>, user: AuthUser) -> Result<Json<Vec<Value>>, ApiError> {
    let mut out = Vec::new();
    for f in feeds::list_for_user(&s.pool, user.id).await? {
        out.push(json!({
            "id": f.id, "slug": f.slug, "name": f.name, "description": f.description, "is_active": f.is_active,
            "member": f.role.is_some(), "role": f.role,
            "topics": feeds::topics(&s.pool, f.id).await?, "sources": feeds::sources(&s.pool, f.id).await?,
        }));
    }
    Ok(Json(out))
}

#[derive(Deserialize)]
struct NewFeed { slug: String, name: String, description: Option<String> }

fn valid_slug(s: &str) -> bool {
    (2..=40).contains(&s.len()) && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

async fn create(State(s): State<AppState>, user: AuthUser, Json(b): Json<NewFeed>) -> Result<(StatusCode, Json<Value>), ApiError> {
    if !valid_slug(&b.slug) { return Err(ApiError::BadRequest("slug: 2-40 chars of a-z, 0-9, -".into())); }
    if b.name.trim().is_empty() { return Err(ApiError::BadRequest("name is required".into())); }
    let id = feeds::create(&s.pool, user.id, &b.slug, b.name.trim(), b.description.as_deref()).await.map_err(|e| match e {
        sqlx::Error::Database(ref d) if d.is_unique_violation() => ApiError::Conflict("slug already exists"),
        other => ApiError::Db(other),
    })?;
    Ok((StatusCode::CREATED, Json(json!({"id": id, "slug": b.slug, "name": b.name.trim(), "role": "owner"}))))
}

#[derive(Deserialize, Default)]
struct Join { notify_email: Option<bool>, notify_push: Option<bool> }

async fn join(State(s): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, body: Option<Json<Join>>) -> Result<StatusCode, ApiError> {
    if !feeds::exists(&s.pool, id).await? { return Err(ApiError::NotFound("feed")); }
    let j = body.map(|b| b.0).unwrap_or_default();
    feeds::upsert_membership(&s.pool, user.id, id, j.notify_email, j.notify_push).await?;
    Ok(StatusCode::OK)
}

async fn leave(State(s): State<AppState>, user: AuthUser, Path(id): Path<Uuid>) -> Result<StatusCode, ApiError> {
    feeds::delete_membership(&s.pool, user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn require_member(s: &AppState, user: &AuthUser, feed_id: Uuid) -> Result<(), ApiError> {
    if !feeds::exists(&s.pool, feed_id).await? { return Err(ApiError::NotFound("feed")); }
    if feeds::is_member(&s.pool, user.id, feed_id).await? { Ok(()) } else { Err(ApiError::Forbidden) }
}

#[derive(Deserialize)]
struct Topic { topic: String }

async fn add_topic(State(s): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Json(b): Json<Topic>) -> Result<StatusCode, ApiError> {
    require_member(&s, &user, id).await?;
    let topic = b.topic.trim().to_lowercase();
    if topic.is_empty() || topic.len() > 60 { return Err(ApiError::BadRequest("topic: 1-60 chars".into())); }
    feeds::add_topic(&s.pool, id, &topic, user.id).await?;
    Ok(StatusCode::CREATED)
}

async fn remove_topic(State(s): State<AppState>, user: AuthUser, Path((id, topic)): Path<(Uuid, String)>) -> Result<StatusCode, ApiError> {
    require_member(&s, &user, id).await?;
    feeds::remove_topic(&s.pool, id, &topic.to_lowercase()).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SourceBody { url: String }

async fn add_source(State(s): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Json(b): Json<SourceBody>) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_member(&s, &user, id).await?;
    let kind = feedcheck::validate_feed_url(&reqwest::Client::new(), b.url.trim()).await.map_err(ApiError::BadRequest)?;
    feeds::add_source(&s.pool, id, b.url.trim(), feedcheck::kind_str(kind), user.id).await?;
    Ok((StatusCode::CREATED, Json(json!({"url": b.url.trim(), "kind": feedcheck::kind_str(kind)}))))
}

#[derive(Deserialize)]
struct SourceQuery { url: String }

async fn remove_source(State(s): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Query(q): Query<SourceQuery>) -> Result<StatusCode, ApiError> {
    require_member(&s, &user, id).await?;
    feeds::remove_source(&s.pool, id, &q.url).await?;
    Ok(StatusCode::NO_CONTENT)
}
```

- [ ] **Step 6: Run** `cargo test -p pulse-api` → PASS; clippy clean.

- [ ] **Step 7: Commit** `git commit -m "pulse-api: feeds, memberships, topics, validated sources"`

---

### Task 6: Internal routes for the pipeline

**Files:**
- Create: `apps/pulse-api/src/db/briefs.rs`, `apps/pulse-api/src/db/runs.rs`, `apps/pulse-api/src/db/feedback.rs`, `apps/pulse-api/tests/internal.rs`
- Modify: `apps/pulse-api/src/routes/internal.rs`, `apps/pulse-api/src/db/mod.rs`

**Interfaces:**
- Produces: `GET /internal/feeds` → `Vec<pulse_core::Feed>` (active feeds, active sources); `POST /internal/briefs` body `pulse_core::Brief` → 200 `{feed_id, date, created: bool}` (upsert on feed slug + date; unknown slug → 404); `POST /internal/runs` body `pulse_core::RunReport` → 200 `{stored: n}` (upsert per feed; unknown slugs skipped and reported in `skipped: [slug]`); `GET /internal/feedback?feed=slug&since=YYYY-MM-DD` → `[{date, aspect, value, user_id}]`. `db::briefs::{upsert, get, list}`, `db::runs::upsert`, `db::feedback::{upsert, list_since}`.

- [ ] **Step 1: Failing tests** `tests/internal.rs`

```rust
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
    let id: uuid::Uuid = sqlx::query_scalar("insert into feeds (slug, name) values ('engineering','Engineering') returning id").fetch_one(pool).await.unwrap();
    sqlx::query("insert into feed_topics (feed_id, topic) values ($1, 'rust')").bind(id).execute(pool).await.unwrap();
    sqlx::query("insert into feed_sources (feed_id, url, kind) values ($1, 'https://blog.cloudflare.com/rss/', 'rss'), ($1, 'https://old.example/feed', 'rss')").bind(id).execute(pool).await.unwrap();
    sqlx::query("update feed_sources set is_active = false where url like '%old%'").execute(pool).await.unwrap();
    id
}

#[sqlx::test]
async fn internal_feeds_matches_contract(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    seed_feed(&pool).await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::GET, "/internal/feeds", Some(SERVICE_TOKEN), None).await;
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
    let (status, body) = send(&app, Method::POST, "/internal/briefs", Some(SERVICE_TOKEN), Some(brief("2026-09-16", "first"))).await;
    assert_eq!(status, 200);
    assert_eq!(body["created"], true);
    let (status, body) = send(&app, Method::POST, "/internal/briefs", Some(SERVICE_TOKEN), Some(brief("2026-09-16", "second"))).await;
    assert_eq!(status, 200);
    assert_eq!(body["created"], false);
    let (title, payload): (String, serde_json::Value) = sqlx::query_as("select article_title, payload from briefs where feed_id = $1").bind(feed_id).fetch_one(&pool).await.unwrap();
    assert_eq!(title, "second");
    assert_eq!(payload["key_idea"], "k");
    let mut b = brief("2026-09-16", "x"); b["feed_slug"] = json!("nope");
    let (status, _) = send(&app, Method::POST, "/internal/briefs", Some(SERVICE_TOKEN), Some(b)).await;
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
    let (status, body) = send(&app, Method::POST, "/internal/runs", Some(SERVICE_TOKEN), Some(run)).await;
    assert_eq!(status, 200);
    assert_eq!(body["stored"], 1);
    assert_eq!(body["skipped"], json!(["ghost"]));
    let (status, body) = send(&app, Method::GET, "/internal/feedback?feed=engineering&since=2026-09-01", Some(SERVICE_TOKEN), None).await;
    assert_eq!(status, 200);
    assert_eq!(body[0]["aspect"], "brief");
    assert_eq!(body[0]["value"], 1);
}
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: db modules**

`db/briefs.rs`:

```rust
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
pub struct BriefRow { pub feed_id: Uuid, pub date: NaiveDate, pub format: String, pub payload: serde_json::Value, pub article_url: String, pub article_title: String, pub model: Option<String>, pub eval_score: Option<f32> }

/// Returns true when a new row was created.
pub async fn upsert(pool: &PgPool, feed_id: Uuid, b: &pulse_core::Brief) -> sqlx::Result<bool> {
    let date = NaiveDate::parse_from_str(&b.date, "%Y-%m-%d").map_err(|e| sqlx::Error::Protocol(format!("bad date: {e}")))?;
    let payload = serde_json::to_value(&b.payload).expect("brief payload serializes");
    let created: bool = sqlx::query_scalar(
        "insert into briefs (feed_id, date, format, payload, article_url, article_title, model, eval_score) values ($1,$2,$3,$4,$5,$6,$7,$8)
         on conflict (feed_id, date) do update set format = excluded.format, payload = excluded.payload, article_url = excluded.article_url, article_title = excluded.article_title, model = excluded.model, eval_score = excluded.eval_score
         returning (xmax = 0)")
        .bind(feed_id).bind(date).bind(&b.format).bind(payload).bind(&b.article_url).bind(&b.article_title).bind(&b.model).bind(b.eval_score.map(|v| v as f32))
        .fetch_one(pool).await?;
    Ok(created)
}

pub async fn get(pool: &PgPool, feed_id: Uuid, date: NaiveDate) -> sqlx::Result<Option<BriefRow>> {
    sqlx::query_as("select feed_id, date, format, payload, article_url, article_title, model, eval_score from briefs where feed_id = $1 and date = $2").bind(feed_id).bind(date).fetch_optional(pool).await
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct BriefSummary { pub date: NaiveDate, pub article_title: String, pub article_url: String, pub snippet: String, pub model: Option<String>, pub eval_score: Option<f32> }

pub async fn list(pool: &PgPool, feed_id: Uuid, before: Option<NaiveDate>, limit: i64) -> sqlx::Result<Vec<BriefSummary>> {
    sqlx::query_as("select date, article_title, article_url, left(payload->>'key_idea', 160) as snippet, model, eval_score from briefs where feed_id = $1 and ($2::date is null or date < $2) order by date desc limit $3")
        .bind(feed_id).bind(before).bind(limit).fetch_all(pool).await
}

pub async fn feed_id_by_slug(pool: &PgPool, slug: &str) -> sqlx::Result<Option<Uuid>> {
    sqlx::query_scalar("select id from feeds where slug = $1").bind(slug).fetch_optional(pool).await
}
```

`db/runs.rs`:

```rust
use chrono::NaiveDate;
use pulse_core::{FeedRun, RunStatus};
use sqlx::PgPool;
use uuid::Uuid;

fn status_str(s: RunStatus) -> &'static str { match s { RunStatus::Ok => "ok", RunStatus::Skipped => "skipped", RunStatus::Failed => "failed" } }

pub async fn upsert(pool: &PgPool, date: NaiveDate, feed_id: Uuid, r: &FeedRun) -> sqlx::Result<()> {
    sqlx::query("insert into runs (date, feed_id, status, article_url, input_tokens, output_tokens, est_cost_usd, error) values ($1,$2,$3,$4,$5,$6,$7,$8)
        on conflict (date, feed_id) do update set status = excluded.status, article_url = excluded.article_url, input_tokens = excluded.input_tokens, output_tokens = excluded.output_tokens, est_cost_usd = excluded.est_cost_usd, error = excluded.error")
        .bind(date).bind(feed_id).bind(status_str(r.status)).bind(&r.article_url).bind(r.input_tokens as i64).bind(r.output_tokens as i64).bind(r.est_cost_usd).bind(&r.error)
        .execute(pool).await.map(|_| ())
}
```

`db/feedback.rs`:

```rust
use chrono::NaiveDate;
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct FeedbackRow { pub user_id: Uuid, pub date: NaiveDate, pub aspect: String, pub value: i16 }

pub async fn upsert(pool: &PgPool, user_id: Uuid, feed_id: Uuid, date: NaiveDate, aspect: &str, value: i16) -> sqlx::Result<()> {
    sqlx::query("insert into feedback (user_id, feed_id, date, aspect, value) values ($1,$2,$3,$4,$5) on conflict (user_id, feed_id, date, aspect) do update set value = excluded.value, created_at = now()")
        .bind(user_id).bind(feed_id).bind(date).bind(aspect).bind(value).execute(pool).await.map(|_| ())
}

pub async fn list_since(pool: &PgPool, feed_id: Uuid, since: NaiveDate) -> sqlx::Result<Vec<FeedbackRow>> {
    sqlx::query_as("select user_id, date, aspect, value from feedback where feed_id = $1 and date >= $2 order by date desc").bind(feed_id).bind(since).fetch_all(pool).await
}
```

- [ ] **Step 4: Routes** `routes/internal.rs`

```rust
use crate::{auth::extractors::ServiceToken, db::{briefs, feedback, feeds, runs}, error::ApiError, state::AppState};
use axum::{extract::{Query, State}, routing::{get, post}, Json, Router};
use chrono::NaiveDate;
use pulse_core::{Brief, Feed, FeedSource, RunReport, SourceKind};
use serde::Deserialize;
use serde_json::{json, Value};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/internal/feeds", get(list_feeds))
        .route("/internal/briefs", post(ingest_brief))
        .route("/internal/runs", post(ingest_runs))
        .route("/internal/feedback", get(list_feedback))
}

fn parse_date(s: &str) -> Result<NaiveDate, ApiError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").map_err(|_| ApiError::BadRequest(format!("bad date: {s}")))
}

fn kind_of(s: &str) -> SourceKind {
    match s { "atom" => SourceKind::Atom, "hackernews" => SourceKind::HackerNews, _ => SourceKind::Rss }
}

async fn list_feeds(State(s): State<AppState>, _t: ServiceToken) -> Result<Json<Vec<Feed>>, ApiError> {
    let rows: Vec<(uuid::Uuid, String, String, Option<String>, bool)> = sqlx::query_as("select id, slug, name, description, is_active from feeds where is_active order by slug").fetch_all(&s.pool).await?;
    let mut out = Vec::new();
    for (id, slug, name, description, is_active) in rows {
        out.push(Feed {
            slug, name, description, is_active,
            topics: feeds::topics(&s.pool, id).await?,
            sources: feeds::sources(&s.pool, id).await?.into_iter().map(|r| FeedSource { url: r.url, kind: kind_of(&r.kind) }).collect(),
        });
    }
    Ok(Json(out))
}

async fn ingest_brief(State(s): State<AppState>, _t: ServiceToken, Json(b): Json<Brief>) -> Result<Json<Value>, ApiError> {
    parse_date(&b.date)?;
    let feed_id = briefs::feed_id_by_slug(&s.pool, &b.feed_slug).await?.ok_or(ApiError::NotFound("feed"))?;
    let created = briefs::upsert(&s.pool, feed_id, &b).await?;
    // Phase 1: fan-out is off; Phase 3 triggers notifications here.
    Ok(Json(json!({"feed_id": feed_id, "date": b.date, "created": created})))
}

async fn ingest_runs(State(s): State<AppState>, _t: ServiceToken, Json(r): Json<RunReport>) -> Result<Json<Value>, ApiError> {
    let date = parse_date(&r.date)?;
    let (mut stored, mut skipped) = (0, Vec::new());
    for fr in &r.feeds {
        match briefs::feed_id_by_slug(&s.pool, &fr.feed_slug).await? {
            Some(id) => { runs::upsert(&s.pool, date, id, fr).await?; stored += 1; }
            None => skipped.push(fr.feed_slug.clone()),
        }
    }
    Ok(Json(json!({"stored": stored, "skipped": skipped})))
}

#[derive(Deserialize)]
struct FeedbackQuery { feed: String, since: String }

async fn list_feedback(State(s): State<AppState>, _t: ServiceToken, Query(q): Query<FeedbackQuery>) -> Result<Json<Vec<feedback::FeedbackRow>>, ApiError> {
    let feed_id = briefs::feed_id_by_slug(&s.pool, &q.feed).await?.ok_or(ApiError::NotFound("feed"))?;
    Ok(Json(feedback::list_since(&s.pool, feed_id, parse_date(&q.since)?).await?))
}
```

- [ ] **Step 5: Run** `cargo test -p pulse-api` → PASS.

- [ ] **Step 6: Commit** `git commit -m "pulse-api: internal feeds/briefs/runs/feedback for the pipeline"`

---

### Task 7: Brief reads, feedback and devices for apps

**Files:**
- Create: `apps/pulse-api/src/db/devices.rs`, `apps/pulse-api/tests/briefs.rs`, `apps/pulse-api/tests/devices.rs`
- Modify: `apps/pulse-api/src/routes/briefs.rs`, `apps/pulse-api/src/routes/devices.rs`, `apps/pulse-api/src/db/mod.rs`

**Interfaces:**
- Produces: `GET /v1/feeds/{id}/briefs?before=YYYY-MM-DD&limit=30` → `[{date, article_title, article_url, snippet, model, eval_score}]` (member only); `GET /v1/briefs/{slug}/{date}` → full `pulse_core::Brief` JSON (member only); `PUT /v1/briefs/{slug}/{date}/feedback {aspect, value}` → 204 (aspect ∈ `brief|selection`, value ∈ -1|1); `PUT /v1/devices {platform, token, app_version?}` → 204 (upsert by token); `DELETE /v1/devices {token}` → 204.

- [ ] **Step 1: Failing tests** `tests/briefs.rs`

```rust
mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

async fn feed_with_briefs(pool: &PgPool, user_id: uuid::Uuid) -> uuid::Uuid {
    let id: uuid::Uuid = sqlx::query_scalar("insert into feeds (slug, name) values ('engineering','E') returning id").fetch_one(pool).await.unwrap();
    sqlx::query("insert into memberships (user_id, feed_id) values ($1, $2)").bind(user_id).bind(id).execute(pool).await.unwrap();
    for d in ["2026-09-14", "2026-09-15", "2026-09-16"] {
        sqlx::query("insert into briefs (feed_id, date, format, payload, article_url, article_title, model, eval_score) values ($1, $2::date, 'insight-brief-v3', $3, 'https://e/x', $2, 'claude-opus-5', 0.9)")
            .bind(id).bind(d).bind(json!({"key_idea": format!("idea {d}"), "why_it_matters": "w", "what_to_change": null, "deep_dive": "d", "meta": null})).execute(pool).await.unwrap();
    }
    id
}

#[sqlx::test]
async fn list_paginates_and_requires_membership(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    let (_, stranger) = registered_user(&pool, "s@example.com", false).await;
    let id = feed_with_briefs(&pool, uid).await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::GET, &format!("/v1/feeds/{id}/briefs?limit=2"), Some(&t), None).await;
    assert_eq!(status, 200);
    assert_eq!(body.as_array().unwrap().len(), 2);
    assert_eq!(body[0]["date"], "2026-09-16");
    assert_eq!(body[0]["snippet"], "idea 2026-09-16");
    let (_, body) = send(&app, Method::GET, &format!("/v1/feeds/{id}/briefs?before=2026-09-15"), Some(&t), None).await;
    assert_eq!(body.as_array().unwrap().len(), 1);
    let (status, _) = send(&app, Method::GET, &format!("/v1/feeds/{id}/briefs"), Some(&stranger), None).await;
    assert_eq!(status, 403);
}

#[sqlx::test]
async fn get_brief_returns_contract_shape(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    feed_with_briefs(&pool, uid).await;
    let app = app(pool, &url);
    let (status, body) = send(&app, Method::GET, "/v1/briefs/engineering/2026-09-15", Some(&t), None).await;
    assert_eq!(status, 200);
    let b: pulse_core::Brief = serde_json::from_value(body).unwrap();
    assert_eq!(b.payload.key_idea, "idea 2026-09-15");
    assert_eq!(b.feed_slug, "engineering");
    let (status, _) = send(&app, Method::GET, "/v1/briefs/engineering/2026-01-01", Some(&t), None).await;
    assert_eq!(status, 404);
}

#[sqlx::test]
async fn feedback_upserts(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    let fid = feed_with_briefs(&pool, uid).await;
    let app = app(pool.clone(), &url);
    for v in [1, -1] {
        let (status, _) = send(&app, Method::PUT, "/v1/briefs/engineering/2026-09-15/feedback", Some(&t), Some(json!({"aspect": "brief", "value": v}))).await;
        assert_eq!(status, 204);
    }
    let v: i16 = sqlx::query_scalar("select value from feedback where user_id = $1 and feed_id = $2").bind(uid).bind(fid).fetch_one(&pool).await.unwrap();
    assert_eq!(v, -1);
    let (status, _) = send(&app, Method::PUT, "/v1/briefs/engineering/2026-09-15/feedback", Some(&t), Some(json!({"aspect": "tone", "value": 1}))).await;
    assert_eq!(status, 422);
}
```

`tests/devices.rs`:

```rust
mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test]
async fn device_upsert_and_delete(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "d@example.com", false).await;
    let app = app(pool.clone(), &url);
    for ver in ["1.0", "1.1"] {
        let (status, _) = send(&app, Method::PUT, "/v1/devices", Some(&t), Some(json!({"platform": "ios", "token": "tok-1", "app_version": ver}))).await;
        assert_eq!(status, 204);
    }
    let (n, ver): (i64, String) = sqlx::query_as("select count(*), max(app_version) from device_tokens where user_id = $1").bind(uid).fetch_one(&pool).await.unwrap();
    assert_eq!((n, ver.as_str()), (1, "1.1"));
    let (status, _) = send(&app, Method::PUT, "/v1/devices", Some(&t), Some(json!({"platform": "web", "token": "x"}))).await;
    assert_eq!(status, 422);
    let (status, _) = send(&app, Method::DELETE, "/v1/devices", Some(&t), Some(json!({"token": "tok-1"}))).await;
    assert_eq!(status, 204);
    let n: i64 = sqlx::query_scalar("select count(*) from device_tokens where user_id = $1 and is_active").bind(uid).fetch_one(&pool).await.unwrap();
    assert_eq!(n, 0);
}
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Devices db** `db/devices.rs`

```rust
use sqlx::PgPool;
use uuid::Uuid;

pub async fn upsert(pool: &PgPool, user_id: Uuid, platform: &str, token: &str, app_version: Option<&str>) -> sqlx::Result<()> {
    sqlx::query("insert into device_tokens (user_id, platform, token, app_version) values ($1,$2,$3,$4) on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, app_version = excluded.app_version, is_active = true, updated_at = now()")
        .bind(user_id).bind(platform).bind(token).bind(app_version).execute(pool).await.map(|_| ())
}

pub async fn deactivate(pool: &PgPool, user_id: Uuid, token: &str) -> sqlx::Result<()> {
    sqlx::query("update device_tokens set is_active = false, updated_at = now() where user_id = $1 and token = $2").bind(user_id).bind(token).execute(pool).await.map(|_| ())
}
```

- [ ] **Step 4: Routes** `routes/briefs.rs`

```rust
use crate::{auth::extractors::AuthUser, db::{briefs, feedback, feeds}, error::ApiError, state::AppState};
use axum::{extract::{Path, Query, State}, http::StatusCode, routing::{get, put}, Json, Router};
use chrono::NaiveDate;
use pulse_core::{Brief, InsightBrief};
use serde::Deserialize;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/feeds/{id}/briefs", get(list))
        .route("/v1/briefs/{slug}/{date}", get(get_one))
        .route("/v1/briefs/{slug}/{date}/feedback", put(put_feedback))
}

#[derive(Deserialize)]
struct ListQuery { before: Option<String>, limit: Option<i64> }

fn parse_date(s: &str) -> Result<NaiveDate, ApiError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d").map_err(|_| ApiError::BadRequest(format!("bad date: {s}")))
}

async fn member_feed(s: &AppState, user: &AuthUser, feed_id: Uuid) -> Result<(), ApiError> {
    if !feeds::exists(&s.pool, feed_id).await? { return Err(ApiError::NotFound("feed")); }
    if feeds::is_member(&s.pool, user.id, feed_id).await? { Ok(()) } else { Err(ApiError::Forbidden) }
}

async fn list(State(s): State<AppState>, user: AuthUser, Path(id): Path<Uuid>, Query(q): Query<ListQuery>) -> Result<Json<Vec<briefs::BriefSummary>>, ApiError> {
    member_feed(&s, &user, id).await?;
    let before = q.before.as_deref().map(parse_date).transpose()?;
    Ok(Json(briefs::list(&s.pool, id, before, q.limit.unwrap_or(30).clamp(1, 100)).await?))
}

async fn get_one(State(s): State<AppState>, user: AuthUser, Path((slug, date)): Path<(String, String)>) -> Result<Json<Brief>, ApiError> {
    let feed_id = briefs::feed_id_by_slug(&s.pool, &slug).await?.ok_or(ApiError::NotFound("feed"))?;
    member_feed(&s, &user, feed_id).await?;
    let row = briefs::get(&s.pool, feed_id, parse_date(&date)?).await?.ok_or(ApiError::NotFound("brief"))?;
    let payload: InsightBrief = serde_json::from_value(row.payload).map_err(|e| ApiError::Internal(format!("stored payload: {e}")))?;
    Ok(Json(Brief { feed_slug: slug, date: row.date.to_string(), format: row.format, payload, article_url: row.article_url, article_title: row.article_title, model: row.model, eval_score: row.eval_score.map(f64::from) }))
}

#[derive(Deserialize)]
struct FeedbackBody { aspect: String, value: i16 }

async fn put_feedback(State(s): State<AppState>, user: AuthUser, Path((slug, date)): Path<(String, String)>, Json(b): Json<FeedbackBody>) -> Result<StatusCode, ApiError> {
    if !matches!(b.aspect.as_str(), "brief" | "selection") || !matches!(b.value, -1 | 1) {
        return Err(ApiError::BadRequest("aspect must be brief|selection and value -1|1".into()));
    }
    let feed_id = briefs::feed_id_by_slug(&s.pool, &slug).await?.ok_or(ApiError::NotFound("feed"))?;
    member_feed(&s, &user, feed_id).await?;
    feedback::upsert(&s.pool, user.id, feed_id, parse_date(&date)?, &b.aspect, b.value).await?;
    Ok(StatusCode::NO_CONTENT)
}
```

`routes/devices.rs`:

```rust
use crate::{auth::extractors::AuthUser, db::devices, error::ApiError, state::AppState};
use axum::{extract::State, http::StatusCode, routing::put, Json, Router};
use serde::Deserialize;

pub fn routes() -> Router<AppState> { Router::new().route("/v1/devices", put(register).delete(remove)) }

#[derive(Deserialize)]
struct Register { platform: String, token: String, app_version: Option<String> }

async fn register(State(s): State<AppState>, user: AuthUser, Json(b): Json<Register>) -> Result<StatusCode, ApiError> {
    if !matches!(b.platform.as_str(), "ios" | "android") || b.token.trim().is_empty() {
        return Err(ApiError::BadRequest("platform must be ios|android and token non-empty".into()));
    }
    devices::upsert(&s.pool, user.id, &b.platform, b.token.trim(), b.app_version.as_deref()).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct Remove { token: String }

async fn remove(State(s): State<AppState>, user: AuthUser, Json(b): Json<Remove>) -> Result<StatusCode, ApiError> {
    devices::deactivate(&s.pool, user.id, &b.token).await?;
    Ok(StatusCode::NO_CONTENT)
}
```

- [ ] **Step 5: Run** `cargo test -p pulse-api` → PASS; clippy clean.

- [ ] **Step 6: Commit** `git commit -m "pulse-api: brief reads, feedback, device tokens"`

---

### Task 8: Seed command

**Files:**
- Modify: `apps/pulse-api/src/seed.rs`, `apps/pulse-api/tests/seed.rs` (create)

**Interfaces:**
- Produces: `pulse-api seed --sources <url-or-path> --invite <CODE> [--invite-uses N]` (idempotent): upserts feed `engineering` ("Engineering", "Systems, infrastructure, AI tooling"), replaces its active sources with the file's entries (kind from `type`), and upserts an invite with `max_uses` (default 5, no expiry). `seed::run(pool, args) -> Result<(), String>`; `seed::apply(pool, sources: &[SourceEntry], invite: &str, uses: i32) -> Result<Summary, String>`.

- [ ] **Step 1: Failing test** `tests/seed.rs`

```rust
use pulse_api::seed::{apply, SourceEntry};
use sqlx::PgPool;

#[sqlx::test]
async fn seed_is_idempotent(pool: PgPool) {
    let src = vec![
        SourceEntry { name: "One".into(), r#type: "rss".into(), url: "https://a/feed".into() },
        SourceEntry { name: "HN".into(), r#type: "hackernews".into(), url: "https://hn/top".into() },
    ];
    let s1 = apply(&pool, &src, "FRIENDS", 5).await.unwrap();
    let s2 = apply(&pool, &src[..1], "FRIENDS", 5).await.unwrap();
    assert_eq!((s1.sources_active, s2.sources_active), (2, 1));
    let feeds: i64 = sqlx::query_scalar("select count(*) from feeds where slug = 'engineering'").fetch_one(&pool).await.unwrap();
    let invites: i64 = sqlx::query_scalar("select count(*) from invites where code = 'FRIENDS'").fetch_one(&pool).await.unwrap();
    assert_eq!((feeds, invites), (1, 1));
    let inactive: i64 = sqlx::query_scalar("select count(*) from feed_sources where not is_active").fetch_one(&pool).await.unwrap();
    assert_eq!(inactive, 1);
}
```

- [ ] **Step 2: Implementation** `seed.rs`

```rust
use serde::Deserialize;
use sqlx::PgPool;

#[derive(Debug, Deserialize)]
pub struct SourceEntry { pub name: String, pub r#type: String, pub url: String }

#[derive(Debug, Default)]
pub struct Summary { pub sources_active: usize }

pub async fn run(pool: &PgPool, args: &[String]) -> Result<(), String> {
    let get = |flag: &str| args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned();
    let sources = get("--sources").ok_or("--sources <url-or-path> is required")?;
    let invite = get("--invite").ok_or("--invite <CODE> is required")?;
    let uses: i32 = get("--invite-uses").map(|v| v.parse().map_err(|_| "--invite-uses must be a number".to_string())).transpose()?.unwrap_or(5);
    let raw = if sources.starts_with("http") {
        reqwest::get(&sources).await.and_then(|r| r.error_for_status()).map_err(|e| e.to_string())?.text().await.map_err(|e| e.to_string())?
    } else {
        std::fs::read_to_string(&sources).map_err(|e| e.to_string())?
    };
    let entries: Vec<SourceEntry> = serde_json::from_str(&raw).map_err(|e| format!("sources json: {e}"))?;
    let s = apply(pool, &entries, &invite, uses).await?;
    println!("seeded engineering: {} active sources; invite {invite} ({uses} uses)", s.sources_active);
    Ok(())
}

pub async fn apply(pool: &PgPool, sources: &[SourceEntry], invite: &str, uses: i32) -> Result<Summary, String> {
    let mut tx = pool.begin().await.map_err(|e| e.to_string())?;
    let feed_id: uuid::Uuid = sqlx::query_scalar("insert into feeds (slug, name, description) values ('engineering', 'Engineering', 'Systems, infrastructure, AI tooling') on conflict (slug) do update set name = excluded.name returning id")
        .fetch_one(&mut *tx).await.map_err(|e| e.to_string())?;
    sqlx::query("update feed_sources set is_active = false where feed_id = $1").bind(feed_id).execute(&mut *tx).await.map_err(|e| e.to_string())?;
    for s in sources {
        let kind = match s.r#type.as_str() { "atom" => "atom", "hackernews" => "hackernews", _ => "rss" };
        sqlx::query("insert into feed_sources (feed_id, url, kind) values ($1, $2, $3) on conflict (feed_id, url) do update set kind = excluded.kind, is_active = true")
            .bind(feed_id).bind(&s.url).bind(kind).execute(&mut *tx).await.map_err(|e| e.to_string())?;
    }
    sqlx::query("insert into invites (code, max_uses) values ($1, $2) on conflict (code) do update set max_uses = excluded.max_uses")
        .bind(invite).bind(uses).execute(&mut *tx).await.map_err(|e| e.to_string())?;
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(Summary { sources_active: sources.len() })
}
```

- [ ] **Step 3: Run** `cargo test -p pulse-api --test seed` → PASS. Manual: `pulse-api seed --sources https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json --invite TESTCODE` against the local DB prints the summary.

- [ ] **Step 4: Commit** `git commit -m "pulse-api: seed command for the engineering feed and first invite"`

---

### Task 9: Pipeline dual-write

**Files:**
- Create: `apps/daily-agent/src/api_client.rs`
- Modify: `apps/daily-agent/Cargo.toml` (add `pulse-core = { path = "../../libs/pulse-core" }`), `apps/daily-agent/src/main.rs` (after the manifest entry gets its `eval_score`, before the final manifest upload), `.github/workflows/ci.yml` (`deploy-agents` daily job env), `apps/daily-agent/README.md`

**Interfaces:**
- Produces: `PulseApi::from_env() -> Option<PulseApi>` (needs `PULSE_API_URL` and `PIPELINE_SERVICE_TOKEN`); `PulseApi::post_brief(&self, &pulse_core::Brief) -> Result<(), String>`; `PulseApi::healthz(&self) -> Result<(), String>`; `brief_for_api(date, brief_json: &str, article_url, article_title, model, eval_score) -> Result<Brief, String>`.

- [ ] **Step 1: Failing tests** in `api_client.rs` (unit, wiremock)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::{matchers::{bearer_token, body_partial_json, method, path}, Mock, MockServer, ResponseTemplate};

    const V3: &str = r#"{"key_idea":"k","why_it_matters":"w","what_to_change":null,"deep_dive":"d","meta":{"confidence":0.9,"category":"c"}}"#;

    #[tokio::test]
    async fn posts_brief_with_service_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).and(path("/internal/briefs")).and(bearer_token("tok"))
            .and(body_partial_json(serde_json::json!({"feed_slug": "engineering", "date": "2026-09-16", "article_title": "T"})))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"created": true}))).expect(1).mount(&server).await;
        let api = PulseApi::new(server.uri(), "tok".into());
        let b = brief_for_api("2026-09-16", V3, "https://x", "T", Some("claude-opus-5"), Some(0.9)).unwrap();
        api.post_brief(&b).await.unwrap();
    }

    #[tokio::test]
    async fn server_error_is_reported_not_panicked() {
        let server = MockServer::start().await;
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(500)).mount(&server).await;
        let api = PulseApi::new(server.uri(), "tok".into());
        let b = brief_for_api("2026-09-16", V3, "https://x", "T", None, None).unwrap();
        assert!(api.post_brief(&b).await.unwrap_err().contains("500"));
    }

    #[test]
    fn from_env_requires_both_vars() {
        assert!(PulseApi::from_pair(None, Some("t".into())).is_none());
        assert!(PulseApi::from_pair(Some("https://api".into()), Some("t".into())).is_some());
    }

    #[test]
    fn invalid_payload_is_error() {
        assert!(brief_for_api("2026-09-16", "{not json", "u", "t", None, None).is_err());
    }
}
```

- [ ] **Step 2: Implementation** `api_client.rs`

```rust
use pulse_core::{Brief, InsightBrief};
use std::time::Duration;

/// Dual-write client for pulse-api. Enabled only when PULSE_API_URL and PIPELINE_SERVICE_TOKEN are set.
pub struct PulseApi { base: String, token: String, http: reqwest::Client }

impl PulseApi {
    pub fn new(base: String, token: String) -> Self {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(20)).build().expect("client");
        Self { base: base.trim_end_matches('/').to_string(), token, http }
    }

    pub fn from_pair(url: Option<String>, token: Option<String>) -> Option<Self> {
        match (url, token) {
            (Some(u), Some(t)) if !u.is_empty() && !t.is_empty() => Some(Self::new(u, t)),
            _ => None,
        }
    }

    pub fn from_env() -> Option<Self> {
        Self::from_pair(std::env::var("PULSE_API_URL").ok(), std::env::var("PIPELINE_SERVICE_TOKEN").ok())
    }

    pub async fn post_brief(&self, brief: &Brief) -> Result<(), String> {
        let resp = self.http.post(format!("{}/internal/briefs", self.base)).bearer_auth(&self.token).json(brief).send().await.map_err(|e| e.to_string())?;
        let status = resp.status();
        if status.is_success() { Ok(()) } else { Err(format!("pulse-api returned {status}: {}", resp.text().await.unwrap_or_default())) }
    }

    pub async fn healthz(&self) -> Result<(), String> {
        let resp = self.http.get(format!("{}/healthz", self.base)).send().await.map_err(|e| e.to_string())?;
        if resp.status().is_success() { Ok(()) } else { Err(format!("healthz {}", resp.status())) }
    }
}

pub fn brief_for_api(date: &str, brief_json: &str, article_url: &str, article_title: &str, model: Option<&str>, eval_score: Option<f64>) -> Result<Brief, String> {
    let payload: InsightBrief = serde_json::from_str(brief_json).map_err(|e| format!("brief json: {e}"))?;
    Ok(Brief { feed_slug: "engineering".into(), date: date.into(), format: "insight-brief-v3".into(), payload, article_url: article_url.into(), article_title: article_title.into(), model: model.map(String::from), eval_score })
}
```

- [ ] **Step 3: Wire into `main.rs`** right before the final manifest upload (after `apply_eval_scores` so `eval_score` is known):

```rust
if let Some(api) = api_client::PulseApi::from_env() {
    match api_client::brief_for_api(&today, &brief.json, &best_article.url, &best_article.title, entry.model.as_deref(), entry.eval_score) {
        Ok(b) => match api.post_brief(&b).await {
            Ok(()) => info!("Brief posted to pulse-api"),
            Err(e) => warn!(error = %e, "pulse-api dual-write failed (non-fatal in Phase 1)"),
        },
        Err(e) => warn!(error = %e, "pulse-api brief mapping failed"),
    }
}
```

(`brief.json` and `entry` are the V3 brief and its manifest entry already in scope in `main.rs`; name them as they are in the code.) In `run_smoke`, after the provider checks: `if let Some(api) = api_client::PulseApi::from_env() { api.healthz().await.map_err(|e| format!("pulse-api: {e}"))?; info!("Smoke check passed check=pulse-api"); }`.

- [ ] **Step 4: Deploy wiring** in `.github/workflows/ci.yml`, `deploy-agents`, daily job: `--set-secrets ANTHROPIC_API_KEY=anthropic-api-key:latest,OPENAI_API_KEY=openai-api-key:latest,PIPELINE_SERVICE_TOKEN=pipeline-service-token:latest` and `--update-env-vars=SHADOW_MODEL=claude-fable-5-1,PULSE_API_URL=https://api.eng-pulse.tsvetkov.org`; add `PIPELINE_SERVICE_TOKEN` to the daily job's `--remove-env-vars` list. Run `actionlint -shellcheck= -pyflakes= .github/workflows/ci.yml`. README env table: `PULSE_API_URL`, `PIPELINE_SERVICE_TOKEN` (optional; enables the dual-write).

- [ ] **Step 5: Run** `cargo test -p se-daily-agent` → PASS; `cargo clippy --workspace --all-targets -- -D warnings`.

- [ ] **Step 6: Commit** `git commit -m "daily-agent: dual-write the brief to pulse-api; smoke checks /healthz"`

---

### Task 10: CI, deploy env, runbook

**Files:**
- Modify: `.github/workflows/ci.yml` (`api-it`), `apps/pulse-api/.env.example`, `docs/runbooks/phase0-setup.md` (PULSE_ENV template), root `AGENTS.md`
- Create: `docs/runbooks/phase1-setup.md`

- [ ] **Step 1: `api-it` runs the sqlx tests**: after `cargo build -p pulse-api` add `- run: cargo test -p pulse-api` (env `DATABASE_URL` already set at job level; sqlx creates per-test databases as the superuser `pulse`). Keep the healthz curl step but set `SUPABASE_JWKS_URL=https://example.invalid/jwks SUPABASE_ISSUER=https://example.invalid PIPELINE_SERVICE_TOKEN=ci` on the run line, since `Config::from_env` now requires them. actionlint clean.

- [ ] **Step 2: `.env.example`**

```
DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse
BIND_ADDR=0.0.0.0:8080
RUST_LOG=info
SUPABASE_JWKS_URL=https://<ref>.supabase.co/auth/v1/.well-known/jwks.json
SUPABASE_ISSUER=https://<ref>.supabase.co/auth/v1
SUPABASE_AUDIENCE=authenticated
PIPELINE_SERVICE_TOKEN=<openssl rand -hex 32>
ADMIN_EMAIL=you@example.com
```

- [ ] **Step 3: Runbook** `docs/runbooks/phase1-setup.md`

```markdown
# Phase 1 setup (API MVP)

1. Supabase: create project `eng-pulse` (EU), enable Apple, Google, Email (magic link/OTP), set SMTP (runbook phase0 §1). Copy the project ref.
2. `PULSE_ENV` (GitHub environment `production`): set `SUPABASE_JWKS_URL=https://<ref>.supabase.co/auth/v1/.well-known/jwks.json`, `SUPABASE_ISSUER=https://<ref>.supabase.co/auth/v1`, add `ADMIN_EMAIL=<your email>`. No spaces.
3. GCP: `printf '%s' '<same value as PIPELINE_SERVICE_TOKEN in PULSE_ENV>' | gcloud secrets create pipeline-service-token --project tsvet01 --data-file=-`.
4. Merge; approve `deploy-api`; then `deploy-agents` redeploys the pipeline with `PULSE_API_URL` and the token (smoke checks `/healthz`).
5. Seed on the box: `ssh -i ~/.ssh/pulse-deploy deploy@api.eng-pulse.tsvetkov.org 'cd /opt/pulse && docker compose run --rm pulse-api pulse-api seed --sources https://storage.googleapis.com/tsvet01-agent-brain/config/sources.json --invite <CODE> --invite-uses 5'`.
6. Verify with a real Supabase token (Supabase dashboard → Authentication → Users → generate magic link, or the `supabase` CLI): `curl -H "Authorization: Bearer $JWT" https://api.eng-pulse.tsvetkov.org/v1/me` → `403 invite_required`; `curl -X POST -H "Authorization: Bearer $JWT" -H 'content-type: application/json' -d '{"invite_code":"<CODE>"}' .../v1/users` → `201` with `is_admin: true` for `ADMIN_EMAIL`; `.../v1/feeds` lists `engineering`.
7. Next morning: `psql` on the box (`docker compose exec postgres psql -U pulse -d pulse -c "select date, article_title, model, eval_score from briefs"`) shows the day's brief; GCS and manifest unchanged.
```

Update the `PULSE_ENV` template in `docs/runbooks/phase0-setup.md` §3 with `SUPABASE_AUDIENCE=authenticated` and `ADMIN_EMAIL=`. Root `AGENTS.md`: layout row for `apps/pulse-api` → "API: auth, feeds, briefs, devices; `/internal` for the pipeline".

- [ ] **Step 4: Full verification** `./scripts/validate.sh --quick` and `cargo test --workspace` with `DATABASE_URL` set → all green. Push the branch; PR CI (`api-it`) must be green.

- [ ] **Step 5: Commit** `git commit -m "ci/runbook: pulse-api tests in api-it, Phase 1 setup"`

---

### Task 11: Phase boundary verification (after merge; Anton + me)

- [ ] Prerequisites done (Supabase project, `PULSE_ENV`, `pipeline-service-token`).
- [ ] `deploy-api` and `deploy-agents` green; smoke shows `check=pulse-api`.
- [ ] Seed run on the box; `GET /v1/feeds` with a real token lists `engineering` with 47 sources.
- [ ] Anton signs up with the invite from his phone's Supabase session or curl → `is_admin: true`; mints a second invite via `/admin/invites`.
- [ ] Next 06:00 UTC run: `briefs` has the row, `LLM usage`/manifest unchanged, GCS files unchanged.
- [ ] Record outcomes in memory; Phase 2 (Swift on API) plan starts only after this checklist passes.

## Self-review notes

- Spec §3: every table present in 0002 (including `notifications_sent`, unused until Phase 3). §4: JWKS verification with pinned issuer/audience, invite gate 403, account linking on verified email, service token on `/internal`. §6: all `/v1`, `/internal`, `/admin` routes listed in the spec exist except `/admin` beyond invites (spec names only `/admin/*` generically). §9 row 1: seed + dual-write + fan-out off. §10: sqlx tests in CI, smoke hits `/healthz`.
- Deliberately deferred: rate limiting, CORS (apps talk directly), `GET /internal/feedback` consumers (Phase 4 calibration), `POST /internal/runs` calls from the pipeline (Phase 4; endpoint exists), notification fan-out (Phase 3).
- Type consistency checked: `SourceKind` string mapping lives in `feedcheck::kind_str` and `internal::kind_of`; `Brief`/`RunReport` shapes come from `pulse-core` unchanged.
