# Phase 0: Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay the foundation for the multi-user tier without shipping any product feature: a Cargo workspace with a shared `pulse-core` crate (+ contract fixtures), a `pulse-api` skeleton serving `/healthz`, a single path-filtered CI/deploy workflow, a Terraform-provisioned Hetzner box (Caddy + Postgres + API) with Cloudflare DNS, and the Supabase auth project — all without touching the daily pipeline's behavior.

**Architecture:** Root Cargo workspace (`libs/llm-client`, `libs/pulse-core`, `apps/daily-agent`, `apps/explorer-agent`, `apps/pulse-api`); `pulse-core` owns the JSON contract and emits fixtures under `docs/contracts/`; `pulse-api` is an axum service with sqlx migrations, packaged as a GHCR image; `infra/hetzner` (Terraform: hcloud + cloudflare providers, GCS state) provisions a cx22 that cloud-init turns into a docker-compose host; GitHub Actions deploys the API over SSH. Terraform provisions, CI deploys; secrets live only in the GitHub `production` environment.

**Tech Stack:** Rust 2021 (axum 0.8, sqlx 0.8 postgres/rustls/migrate, tokio, serde, tracing), Terraform ≥ 1.9 (hetznercloud/hcloud ~> 1.50, cloudflare/cloudflare ~> 4.52, hashicorp/google for state bucket bootstrap only via gcloud), Ubuntu 24.04 + docker compose v2 + Caddy 2 + Postgres 16, GitHub Actions (`dorny/paths-filter`, `Swatinem/rust-cache`, `docker/build-push-action`, `appleboy/ssh-action`).

**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md` — sections 2 (architecture), 8 (infra), 9 (Phase 0 row), 12 (repo layout & CI). The spec is the authority; this plan argues from it.

## Global Constraints

- Never commit secrets; nothing secret enters Terraform state (`HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN` via env; runtime secrets via GitHub environment `production` → `/opt/pulse/.env` written by the deploy job).
- The daily pipeline's behavior must not change in this phase (workspace + Dockerfile refactor only; `--smoke` gate must still pass on deploy).
- `cargo fmt --check`, `cargo clippy --workspace -- -D warnings`, `cargo test --workspace` green; TDD for every Rust behavior.
- Hostnames: API at `api.eng-pulse.tsvetkov.org`; `eng-pulse.tsvetkov.org` gets an A record too (reserved, same box). DNS-only (not proxied).
- Hetzner: `cx22`, `ubuntu-24.04`, location `nbg1`, 10 GB volume. Terraform state: GCS bucket `tsvet01-terraform-state`, prefix `hetzner`.
- Fixtures directory: `docs/contracts/` (committed; CI fails on drift).
- Image: `ghcr.io/tsvet01/pulse-api:<git sha>` and `:latest`.
- Real-world verification at the end: `curl https://api.eng-pulse.tsvetkov.org/healthz` returns `{"status":"ok","db":"ok"}` over valid TLS.

## Inputs Anton provides before Task 6 executes (not placeholders — runtime secrets)

- Hetzner Cloud API token (project "eng-pulse"), Cloudflare API token (Zone:DNS:Edit on `tsvetkov.org`) and the zone ID; confirmation that `tsvetkov.org` nameservers are Cloudflare's.
- His public SSH key and admin IP/CIDR for the firewall.
- GitHub environment `production` secrets: `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `DEPLOY_SSH_KEY` (private key for the box's `deploy` user), `PULSE_ENV` (the `.env` file body, see Task 7), `GCS_BACKUP_SA_JSON`. `GCP_CREDENTIALS` already exists (reused for Terraform state access).

---

### Task 1: Root Cargo workspace (+ Dockerfiles that build from it)

**Files:**
- Create: `Cargo.toml` (root)
- Delete: `libs/llm-client/Cargo.lock`, `apps/daily-agent/Cargo.lock`, `apps/explorer-agent/Cargo.lock` (replaced by root `Cargo.lock`)
- Modify: `apps/daily-agent/Dockerfile`, `apps/explorer-agent/Dockerfile`, `.gitignore` (target/)

**Interfaces:**
- Produces: one root `Cargo.lock`; `cargo test --workspace` runs all crates; Docker builds use `cargo build --release -p <crate>` from the repo root.

- [ ] **Step 1: Write the workspace manifest**

```toml
# Cargo.toml (repo root)
[workspace]
resolver = "2"
members = [
    "libs/llm-client",
    "apps/daily-agent",
    "apps/explorer-agent",
]
```

- [ ] **Step 2: Remove per-crate lockfiles, generate the root one, prove parity**

```bash
git rm -q libs/llm-client/Cargo.lock apps/daily-agent/Cargo.lock apps/explorer-agent/Cargo.lock
cargo generate-lockfile
cargo test --workspace 2>&1 | grep "test result"
cargo clippy --workspace -- -D warnings
```
Expected: same test counts as before (llm-client 42, daily-agent 69+3, explorer 17), clippy clean, a single `Cargo.lock` at root. Add `/target/` to `.gitignore` if not present.

- [ ] **Step 3: Rewrite both Dockerfiles for the workspace**

`apps/daily-agent/Dockerfile` (explorer's is identical with `se-explorer-agent` and `CMD` instead of `ENTRYPOINT`, matching today's):

```dockerfile
FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY libs/llm-client/Cargo.toml libs/llm-client/Cargo.toml
COPY apps/daily-agent/Cargo.toml apps/daily-agent/Cargo.toml
COPY apps/explorer-agent/Cargo.toml apps/explorer-agent/Cargo.toml
RUN mkdir -p libs/llm-client/src apps/daily-agent/src apps/explorer-agent/src \
 && echo "pub fn dummy() {}" > libs/llm-client/src/lib.rs \
 && echo "fn main() {}" > apps/daily-agent/src/main.rs \
 && echo "fn main() {}" > apps/explorer-agent/src/main.rs \
 && cargo build --release -p se-daily-agent \
 && rm -rf libs/*/src apps/*/src target/release/.fingerprint/se-daily-agent-* target/release/.fingerprint/llm-client-*
COPY libs libs
COPY apps/daily-agent apps/daily-agent
RUN cargo build --release -p se-daily-agent

FROM debian:bookworm-slim
LABEL org.opencontainers.image.source="https://github.com/tsvet01/eng-pulse"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libssl3 && rm -rf /var/lib/apt/lists/*
RUN useradd --no-create-home --shell /bin/false appuser
COPY --from=builder /app/target/release/se-daily-agent /usr/local/bin/se-daily-agent
USER appuser
ENTRYPOINT ["se-daily-agent"]
```

(When Task 2/3 add `libs/pulse-core` and `apps/pulse-api`, their `Cargo.toml` lines are added to the dependency-caching `COPY` block of both Dockerfiles — the workspace manifest lists them, so cargo needs their manifests present.)

- [ ] **Step 4: Verify the images build locally**

```bash
docker build -f apps/daily-agent/Dockerfile -t se-daily-agent:ws . && docker run --rm se-daily-agent:ws --help 2>&1 | head -3
docker build -f apps/explorer-agent/Dockerfile -t se-explorer-agent:ws .
```
Expected: both build; the daily-agent container starts (it will exit complaining about missing API keys — that's the binary running).

- [ ] **Step 5: Check the local pre-commit hook still passes** (it is not in the repo; it runs per-crate cargo checks) — `git commit` will run it. If it references per-crate `Cargo.lock`, edit `.git/hooks/pre-commit` in the main checkout to run `cargo clippy --workspace -- -D warnings` instead and note it in the report.

- [ ] **Step 6: Commit**

```bash
git add Cargo.toml Cargo.lock .gitignore apps/daily-agent/Dockerfile apps/explorer-agent/Dockerfile
git commit -m "build: root Cargo workspace; Dockerfiles build from workspace root"
```

### Task 2: `pulse-core` crate — domain types and contract fixtures

**Files:**
- Create: `libs/pulse-core/Cargo.toml`, `libs/pulse-core/src/lib.rs`, `libs/pulse-core/src/bin/fixtures.rs`, `docs/contracts/{feed,brief,run_report}.json` (generated), `docs/contracts/README.md`
- Modify: root `Cargo.toml` (add member), both Dockerfiles' manifest `COPY` block

**Interfaces:**
- Produces (used by Phase 1 API and pipeline, and by the mobile tests):

```rust
pub struct Feed { pub slug: String, pub name: String, pub description: Option<String>, pub topics: Vec<String>, pub sources: Vec<FeedSource>, pub is_active: bool }
pub struct FeedSource { pub url: String, pub kind: SourceKind }   // SourceKind: Rss | Atom | HackerNews (serde lowercase, "hackernews")
pub struct InsightBrief { pub key_idea: String, pub why_it_matters: String, pub what_to_change: Option<String>, pub deep_dive: String, pub meta: Option<BriefMeta> }
pub struct BriefMeta { pub confidence: Option<f32>, pub category: Option<String> }
pub struct Brief { pub feed_slug: String, pub date: String /* YYYY-MM-DD */, pub format: String /* "insight-brief-v3" */, pub payload: InsightBrief, pub article_url: String, pub article_title: String, pub model: Option<String>, pub eval_score: Option<f32> }
pub struct RunReport { pub date: String, pub feeds: Vec<FeedRun> }
pub struct FeedRun { pub feed_slug: String, pub status: RunStatus /* Ok | Skipped | Failed */, pub article_url: Option<String>, pub input_tokens: u64, pub output_tokens: u64, pub est_cost_usd: f64, pub error: Option<String> }
pub fn fixtures() -> Vec<(&'static str, serde_json::Value)>   // deterministic sample of each type
```

- [ ] **Step 1: Write the failing tests** (`libs/pulse-core/src/lib.rs`, `mod tests`)

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insight_brief_decodes_production_shape() {
        // Exact shape the daily-agent uploads to summaries/v3/{date}.json today.
        let json = r#"{"key_idea":"k","why_it_matters":"w","what_to_change":null,"deep_dive":"d","meta":{"confidence":0.9,"category":"platform-engineering"}}"#;
        let b: InsightBrief = serde_json::from_str(json).unwrap();
        assert_eq!(b.key_idea, "k");
        assert!(b.what_to_change.is_none());
        assert_eq!(b.meta.unwrap().category.as_deref(), Some("platform-engineering"));
    }

    #[test]
    fn source_kind_serializes_like_sources_json() {
        assert_eq!(serde_json::to_string(&SourceKind::HackerNews).unwrap(), "\"hackernews\"");
        assert_eq!(serde_json::to_string(&SourceKind::Rss).unwrap(), "\"rss\"");
    }

    #[test]
    fn fixtures_are_deterministic_and_round_trip() {
        let a = fixtures();
        let b = fixtures();
        assert_eq!(a, b);
        for (name, value) in a {
            match name {
                "feed" => { let _: Feed = serde_json::from_value(value).unwrap(); }
                "brief" => { let _: Brief = serde_json::from_value(value).unwrap(); }
                "run_report" => { let _: RunReport = serde_json::from_value(value).unwrap(); }
                other => panic!("unexpected fixture {other}"),
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p pulse-core` (after adding the member + a `Cargo.toml` with `serde`, `serde_json` deps and an empty `lib.rs`)
Expected: FAIL — types/`fixtures` not found.

- [ ] **Step 3: Minimal implementation**

`libs/pulse-core/Cargo.toml`:
```toml
[package]
name = "pulse-core"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
```

`libs/pulse-core/src/lib.rs` — the structs from Interfaces with `#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]`; `SourceKind`/`RunStatus` with `#[serde(rename_all = "lowercase")]` and `#[serde(rename = "hackernews")]` on `HackerNews`; and:

```rust
/// Deterministic samples of every contract type; mobile tests decode these.
pub fn fixtures() -> Vec<(&'static str, serde_json::Value)> {
    let feed = Feed {
        slug: "engineering".into(), name: "Engineering".into(),
        description: Some("Systems, infrastructure, AI tooling".into()),
        topics: vec!["distributed systems".into(), "rust".into()],
        sources: vec![FeedSource { url: "https://blog.cloudflare.com/rss/".into(), kind: SourceKind::Rss }],
        is_active: true,
    };
    let brief = Brief {
        feed_slug: "engineering".into(), date: "2026-09-01".into(), format: "insight-brief-v3".into(),
        payload: InsightBrief {
            key_idea: "One clear sentence.".into(), why_it_matters: "Why the reader cares.".into(),
            what_to_change: Some("One concrete action.".into()), deep_dive: "## Deep dive\n\nMarkdown body.".into(),
            meta: Some(BriefMeta { confidence: Some(0.9), category: Some("platform-engineering".into()) }),
        },
        article_url: "https://example.com/post".into(), article_title: "Example post".into(),
        model: Some("claude-opus-4-8".into()), eval_score: Some(0.95),
    };
    let run = RunReport { date: "2026-09-01".into(), feeds: vec![FeedRun {
        feed_slug: "engineering".into(), status: RunStatus::Ok, article_url: Some("https://example.com/post".into()),
        input_tokens: 2845, output_tokens: 1410, est_cost_usd: 0.049, error: None,
    }] };
    vec![
        ("feed", serde_json::to_value(feed).unwrap()),
        ("brief", serde_json::to_value(brief).unwrap()),
        ("run_report", serde_json::to_value(run).unwrap()),
    ]
}
```

`libs/pulse-core/src/bin/fixtures.rs`:
```rust
//! Writes docs/contracts/*.json. CI regenerates and fails on drift.
fn main() {
    let out = std::env::args().nth(1).unwrap_or_else(|| "docs/contracts".into());
    std::fs::create_dir_all(&out).expect("create contracts dir");
    for (name, value) in pulse_core::fixtures() {
        let path = format!("{out}/{name}.json");
        let pretty = serde_json::to_string_pretty(&value).unwrap() + "\n";
        std::fs::write(&path, pretty).expect("write fixture");
        println!("wrote {path}");
    }
}
```

Add `"libs/pulse-core"` to the workspace members and `COPY libs/pulse-core/Cargo.toml libs/pulse-core/Cargo.toml` to both Dockerfiles' caching block (plus a dummy `lib.rs` line and fingerprint cleanup for `pulse-core-*`).

- [ ] **Step 4: Verify green, generate fixtures**

```bash
cargo test -p pulse-core && cargo clippy --workspace -- -D warnings
cargo run -p pulse-core --bin fixtures -- docs/contracts
git status --short docs/contracts   # three new files
```
Write `docs/contracts/README.md`: one paragraph — "Generated by `cargo run -p pulse-core --bin fixtures`; consumed by Swift/Kotlin contract tests; CI fails if regenerating changes them."

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml libs/pulse-core docs/contracts apps/daily-agent/Dockerfile apps/explorer-agent/Dockerfile
git commit -m "feat(pulse-core): shared contract types + fixture generator"
```

### Task 3: `pulse-api` skeleton — `/healthz`, config, migrations, Dockerfile

**Files:**
- Create: `apps/pulse-api/Cargo.toml`, `apps/pulse-api/src/main.rs`, `apps/pulse-api/src/health.rs`, `apps/pulse-api/migrations/0001_extensions.sql`, `apps/pulse-api/Dockerfile`, `apps/pulse-api/.env.example`
- Modify: root `Cargo.toml` (member), both agent Dockerfiles (manifest COPY line)

**Interfaces:**
- Consumes: env `DATABASE_URL` (postgres://…), `BIND_ADDR` (default `0.0.0.0:8080`).
- Produces: `GET /healthz` → `200 {"status":"ok","db":"ok"}` or `503 {"status":"degraded","db":"error"}`; `health_body(db_ok: bool) -> (StatusCode, Json<Health>)` pure function; migrations run on startup via `sqlx::migrate!()`.

- [ ] **Step 1: Write the failing tests** (`apps/pulse-api/src/health.rs`)

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    #[test]
    fn healthy_when_db_ok() {
        let (status, body) = health_body(true);
        assert_eq!(status, StatusCode::OK);
        assert_eq!(body.0, Health { status: "ok", db: "ok" });
    }

    #[test]
    fn degraded_when_db_down() {
        let (status, body) = health_body(false);
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(body.0, Health { status: "degraded", db: "error" });
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test -p pulse-api` (after `Cargo.toml` + empty modules)
Expected: FAIL — `health_body`/`Health` not found.

- [ ] **Step 3: Minimal implementation**

`apps/pulse-api/Cargo.toml`:
```toml
[package]
name = "pulse-api"
version = "0.1.0"
edition = "2021"

[dependencies]
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
sqlx = { version = "0.8", features = ["runtime-tokio", "tls-rustls", "postgres", "migrate"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
dotenvy = "0.15"
pulse-core = { path = "../../libs/pulse-core" }
```

`apps/pulse-api/src/health.rs`:
```rust
use axum::{extract::State, http::StatusCode, Json};
use serde::Serialize;
use sqlx::PgPool;

#[derive(Serialize, Debug, PartialEq)]
pub struct Health { pub status: &'static str, pub db: &'static str }

pub fn health_body(db_ok: bool) -> (StatusCode, Json<Health>) {
    if db_ok {
        (StatusCode::OK, Json(Health { status: "ok", db: "ok" }))
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, Json(Health { status: "degraded", db: "error" }))
    }
}

pub async fn healthz(State(pool): State<PgPool>) -> (StatusCode, Json<Health>) {
    let db_ok = sqlx::query_scalar::<_, i32>("SELECT 1").fetch_one(&pool).await.is_ok();
    health_body(db_ok)
}
```

`apps/pulse-api/src/main.rs`:
```rust
mod health;

use axum::{routing::get, Router};
use sqlx::postgres::PgPoolOptions;
use tracing::info;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt().with_env_filter(
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into())
    ).json().init();

    let database_url = std::env::var("DATABASE_URL")?;
    let bind = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());

    let pool = PgPoolOptions::new().max_connections(8).connect(&database_url).await?;
    sqlx::migrate!("./migrations").run(&pool).await?;   // refuse to serve if migrations fail

    let app = Router::new().route("/healthz", get(health::healthz)).with_state(pool);
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    info!(%bind, "pulse-api listening");
    axum::serve(listener, app).await?;
    Ok(())
}
```

`apps/pulse-api/migrations/0001_extensions.sql`:
```sql
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

`apps/pulse-api/.env.example`:
```
DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse
BIND_ADDR=0.0.0.0:8080
RUST_LOG=info
```

`apps/pulse-api/Dockerfile`: same two-stage workspace pattern as Task 1 with `-p pulse-api`, runtime `debian:bookworm-slim` + `ca-certificates`, `EXPOSE 8080`, `ENTRYPOINT ["pulse-api"]`.

Add `"apps/pulse-api"` to workspace members and its manifest `COPY` line to the agent Dockerfiles.

- [ ] **Step 4: Verify green + a real local run**

```bash
cargo test -p pulse-api && cargo clippy --workspace -- -D warnings
docker run -d --name pulse-pg -e POSTGRES_USER=pulse -e POSTGRES_PASSWORD=pulse -e POSTGRES_DB=pulse -p 5432:5432 postgres:16
sleep 5 && DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse cargo run -p pulse-api &
sleep 3 && curl -s localhost:8080/healthz && echo && kill %1 && docker rm -f pulse-pg
```
Expected: `{"status":"ok","db":"ok"}`; startup log shows migrations applied.

- [ ] **Step 5: Commit**

```bash
git add Cargo.toml apps/pulse-api apps/daily-agent/Dockerfile apps/explorer-agent/Dockerfile
git commit -m "feat(pulse-api): skeleton with /healthz, sqlx migrations, Dockerfile"
```

### Task 4: Archive the Flutter app

**Files:**
- Delete: `apps/mobile/` (entire tree, via `git rm -r`)
- Modify: `README.md` (component table: replace the Flutter row with "mobile-android — native Kotlin/Compose, planned (Phase 5)"; fix the stale `gemini-engine` link to `libs/llm-client`)

- [ ] **Step 1: Remove and document**

```bash
git rm -r -q apps/mobile
```
Edit `README.md` as above. Grep for remaining references: `grep -rn "apps/mobile\b\|flutter" --include=*.md --include=*.yml . | grep -v mobile-swift` — remove or update each (CI is rewritten in Task 5, so its Flutter job disappears there).

- [ ] **Step 2: Commit**

```bash
git add -A README.md
git commit -m "chore: archive Flutter app (superseded by native Android, spec §7)"
```

### Task 5: Single path-filtered CI + deploy workflow

**Files:**
- Create: `.github/workflows/ci.yml` (rewritten in place)
- Delete: `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: existing secrets `GCP_CREDENTIALS`; environment `production` secrets from the Inputs list; GHCR via `GITHUB_TOKEN` (`packages: write`).
- Produces: jobs `changes`, `rust`, `api-it`, `fixtures`, `swift`, `terraform-plan`, `python`, and main-only `deploy-agents`, `deploy-functions`, `deploy-api`, `terraform-apply`.

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]
  workflow_dispatch:

permissions:
  contents: read
  packages: write
  id-token: write
  pull-requests: write

concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  CARGO_TERM_COLOR: always
  PROJECT_ID: tsvet01
  REGION: us-central1
  REPO_NAME: agent-repo
  IMAGE_TAG: ${{ github.sha }}
  API_IMAGE: ghcr.io/tsvet01/pulse-api

jobs:
  changes:
    runs-on: ubuntu-latest
    outputs:
      rust: ${{ steps.f.outputs.rust }}
      api: ${{ steps.f.outputs.api }}
      agents: ${{ steps.f.outputs.agents }}
      swift: ${{ steps.f.outputs.swift }}
      infra: ${{ steps.f.outputs.infra }}
      functions: ${{ steps.f.outputs.functions }}
    steps:
    - uses: actions/checkout@v6
    - id: f
      uses: dorny/paths-filter@v3
      with:
        filters: |
          rust: ['Cargo.toml', 'Cargo.lock', 'libs/**', 'apps/daily-agent/**', 'apps/explorer-agent/**', 'apps/pulse-api/**']
          api: ['Cargo.toml', 'Cargo.lock', 'libs/**', 'apps/pulse-api/**']
          agents: ['Cargo.toml', 'Cargo.lock', 'libs/**', 'apps/daily-agent/**', 'apps/explorer-agent/**']
          swift: ['apps/mobile-swift/**', 'docs/contracts/**']
          infra: ['infra/**']
          functions: ['functions/**']

  rust:
    needs: changes
    if: needs.changes.outputs.rust == 'true'
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v6
    - uses: dtolnay/rust-toolchain@stable
      with: { components: "clippy, rustfmt" }
    - uses: Swatinem/rust-cache@v2
    - run: cargo fmt --all -- --check
    - run: cargo clippy --workspace -- -D warnings
    - run: cargo test --workspace

  fixtures:
    needs: changes
    if: needs.changes.outputs.rust == 'true'
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v6
    - uses: dtolnay/rust-toolchain@stable
    - uses: Swatinem/rust-cache@v2
    - run: cargo run -p pulse-core --bin fixtures -- docs/contracts
    - name: Fail on fixture drift
      run: git diff --exit-code -- docs/contracts

  api-it:
    needs: changes
    if: needs.changes.outputs.api == 'true'
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_USER: pulse, POSTGRES_PASSWORD: pulse, POSTGRES_DB: pulse }
        ports: ['5432:5432']
        options: >-
          --health-cmd "pg_isready -U pulse" --health-interval 5s --health-timeout 5s --health-retries 10
    env:
      DATABASE_URL: postgres://pulse:pulse@localhost:5432/pulse
    steps:
    - uses: actions/checkout@v6
    - uses: dtolnay/rust-toolchain@stable
    - uses: Swatinem/rust-cache@v2
    - name: Migrations apply and /healthz answers
      run: |
        cargo run -p pulse-api &
        for i in $(seq 1 30); do curl -sf localhost:8080/healthz && break; sleep 1; done
        curl -sf localhost:8080/healthz | grep '"db":"ok"'

  swift:
    needs: changes
    if: needs.changes.outputs.swift == 'true'
    runs-on: macos-latest
    steps:
    - uses: actions/checkout@v6
    - run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    - run: touch apps/mobile-swift/Secrets.xcconfig
    - run: cp apps/mobile-swift/GoogleService-Info.plist.ci apps/mobile-swift/EngPulse/GoogleService-Info.plist
    - name: Build and test
      run: |
        cd apps/mobile-swift
        DEVICE=$(xcrun simctl list devices available --json | jq -r '
          .devices | to_entries | map(select(.key | contains("SimRuntime.iOS")))
          | sort_by(.key) | reverse | map(.value[] | select(.name | startswith("iPhone")))
          | first // empty | "\(.udid) \(.name)"')
        xcodebuild test -scheme EngPulse -sdk iphonesimulator \
          -destination "platform=iOS Simulator,id=${DEVICE%% *}" \
          CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO

  python:
    needs: changes
    if: needs.changes.outputs.functions == 'true'
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v6
    - uses: actions/setup-python@v6
      with: { python-version: '3.12' }
    - run: |
        pip install -r functions/notifier/requirements-dev.txt -r functions/shared/requirements-dev.txt
        for f in notifier fcm-tokens apns-notifier feedback-receiver; do python -m py_compile functions/$f/main.py; done
        (cd functions && python -m pytest shared/ -q)
        for f in notifier apns-notifier fcm-tokens; do (cd functions/$f && python -m pytest test_main.py -q); done
        cp -r functions/shared functions/feedback-receiver/shared
        (cd functions/feedback-receiver && pip install -r requirements.txt -q && python -m pytest test_main.py -q)

  terraform-plan:
    needs: changes
    if: needs.changes.outputs.infra == 'true'
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: infra/hetzner } }
    env:
      HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      TF_VAR_cloudflare_zone_id: ${{ secrets.CLOUDFLARE_ZONE_ID }}
      TF_VAR_admin_cidr: ${{ secrets.ADMIN_CIDR }}
      TF_VAR_ssh_public_key: ${{ secrets.SSH_PUBLIC_KEY }}
    steps:
    - uses: actions/checkout@v6
    - uses: google-github-actions/auth@v3
      with: { credentials_json: "${{ secrets.GCP_CREDENTIALS }}" }
    - uses: hashicorp/setup-terraform@v3
      with: { terraform_version: "1.9.8" }
    - run: terraform fmt -check -recursive
    - run: terraform init -input=false
    - run: terraform validate
    - id: plan
      run: terraform plan -no-color -input=false -out=tfplan 2>&1 | tee plan.txt
    - name: Post plan on PR
      if: github.event_name == 'pull_request'
      uses: actions/github-script@v7
      with:
        script: |
          const fs = require('fs');
          const plan = fs.readFileSync('infra/hetzner/plan.txt', 'utf8').slice(0, 60000);
          await github.rest.issues.createComment({ ...context.repo, issue_number: context.issue.number,
            body: '### Terraform plan (infra/hetzner)\n```\n' + plan + '\n```' });

  # ---------------- main only ----------------
  deploy-agents:
    needs: [changes, rust, fixtures]
    if: github.ref == 'refs/heads/main' && needs.changes.outputs.agents == 'true'
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v6
    - uses: google-github-actions/auth@v3
      with: { credentials_json: "${{ secrets.GCP_CREDENTIALS }}" }
    - uses: google-github-actions/setup-gcloud@v3
    - run: gcloud auth configure-docker ${{ env.REGION }}-docker.pkg.dev --quiet
    - name: Build & deploy daily-agent
      run: |
        gcloud builds submit --config=apps/daily-agent/cloudbuild.yaml \
          --substitutions=_IMAGE_TAG=${{ env.REGION }}-docker.pkg.dev/${{ env.PROJECT_ID }}/${{ env.REPO_NAME }}/se-daily-agent:${{ env.IMAGE_TAG }} \
          --machine-type=E2_HIGHCPU_8 .
        gcloud run jobs update se-daily-agent-job --region ${{ env.REGION }} --project ${{ env.PROJECT_ID }} \
          --remove-env-vars GEMINI_API_KEY,ANTHROPIC_API_KEY --clear-secrets || true
        gcloud run jobs deploy se-daily-agent-job \
          --image ${{ env.REGION }}-docker.pkg.dev/${{ env.PROJECT_ID }}/${{ env.REPO_NAME }}/se-daily-agent:${{ env.IMAGE_TAG }} \
          --region ${{ env.REGION }} --project ${{ env.PROJECT_ID }} \
          --set-secrets GEMINI_API_KEY=gemini-api-key:latest,ANTHROPIC_API_KEY=anthropic-api-key:latest \
          --update-env-vars=SHADOW_MODEL=claude-opus-5 --task-timeout 10m
    - name: Build & deploy explorer-agent
      run: |
        gcloud builds submit --config=apps/explorer-agent/cloudbuild.yaml \
          --substitutions=_IMAGE_TAG=${{ env.REGION }}-docker.pkg.dev/${{ env.PROJECT_ID }}/${{ env.REPO_NAME }}/se-explorer-agent:${{ env.IMAGE_TAG }} \
          --machine-type=E2_HIGHCPU_8 .
        gcloud run jobs update se-explorer-agent-job --region ${{ env.REGION }} --project ${{ env.PROJECT_ID }} \
          --remove-env-vars GEMINI_API_KEY,ANTHROPIC_API_KEY --clear-secrets || true
        gcloud run jobs deploy se-explorer-agent-job \
          --image ${{ env.REGION }}-docker.pkg.dev/${{ env.PROJECT_ID }}/${{ env.REPO_NAME }}/se-explorer-agent:${{ env.IMAGE_TAG }} \
          --region ${{ env.REGION }} --project ${{ env.PROJECT_ID }} \
          --set-secrets GEMINI_API_KEY=gemini-api-key:latest,ANTHROPIC_API_KEY=anthropic-api-key:latest \
          --task-timeout 30m
    - name: Smoke gate (real LLM call per provider + shadow model)
      run: gcloud run jobs execute se-daily-agent-job --region ${{ env.REGION }} --project ${{ env.PROJECT_ID }} --args=--smoke --wait

  deploy-functions:
    needs: [changes, python]
    if: github.ref == 'refs/heads/main' && needs.changes.outputs.functions == 'true'
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v6
    - uses: google-github-actions/auth@v3
      with: { credentials_json: "${{ secrets.GCP_CREDENTIALS }}" }
    - uses: google-github-actions/setup-gcloud@v3
    - name: Deploy all four functions (same flags as before)
      run: |
        set -e
        for f in notifier feedback-receiver apns-notifier fcm-tokens; do cp -r functions/shared functions/$f/shared; done
        (cd functions/notifier && gcloud functions deploy se-daily-notifier --gen2 --runtime=python312 --region=${{ env.REGION }} --source=. --entry-point=send_summary_email \
          --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" --trigger-event-filters="bucket=${{ env.PROJECT_ID }}-agent-brain" --clear-env-vars \
          --set-secrets "GMAIL_USER=gmail-user:latest,GMAIL_APP_PASSWORD=gmail-app-password:latest,DEST_EMAIL=dest-email:latest" --project ${{ env.PROJECT_ID }})
        (cd functions/feedback-receiver && gcloud functions deploy feedback-receiver --gen2 --runtime=python312 --region=${{ env.REGION }} --project=${{ env.PROJECT_ID }} --source=. --entry-point=receive_feedback --trigger-http --allow-unauthenticated)
        (cd functions/apns-notifier && gcloud functions deploy register-apns-token --gen2 --runtime=python312 --region=${{ env.REGION }} --project=${{ env.PROJECT_ID }} --source=. --entry-point=register_apns_token --trigger-http --allow-unauthenticated --memory=256MB --timeout=30s \
          && gcloud functions deploy trigger-apns-notification --gen2 --runtime=python312 --region=${{ env.REGION }} --project=${{ env.PROJECT_ID }} --source=. --entry-point=trigger_apns_notification --trigger-http --allow-unauthenticated --memory=256MB --timeout=60s)
        (cd functions/fcm-tokens && gcloud functions deploy register-token --gen2 --runtime=python312 --region=${{ env.REGION }} --project=${{ env.PROJECT_ID }} --source=. --entry-point=register_token --trigger-http --allow-unauthenticated --memory=256MB --timeout=30s \
          && gcloud functions deploy unregister-token --gen2 --runtime=python312 --region=${{ env.REGION }} --project=${{ env.PROJECT_ID }} --source=. --entry-point=unregister_token --trigger-http --allow-unauthenticated --memory=256MB --timeout=30s)

  deploy-api:
    needs: [changes, rust, api-it]
    if: github.ref == 'refs/heads/main' && needs.changes.outputs.api == 'true'
    runs-on: ubuntu-latest
    environment: production
    steps:
    - uses: actions/checkout@v6
    - uses: docker/login-action@v3
      with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
    - uses: docker/build-push-action@v6
      with:
        context: .
        file: apps/pulse-api/Dockerfile
        push: true
        tags: ${{ env.API_IMAGE }}:${{ env.IMAGE_TAG }},${{ env.API_IMAGE }}:latest
        cache-from: type=gha
        cache-to: type=gha,mode=max
    - name: Write runtime env on the box, pull, restart, health-check
      uses: appleboy/ssh-action@v1
      with:
        host: api.eng-pulse.tsvetkov.org
        username: deploy
        key: ${{ secrets.DEPLOY_SSH_KEY }}
        envs: PULSE_ENV,GCS_BACKUP_SA_JSON,IMAGE_TAG
        script: |
          set -e
          umask 077
          cd /opt/pulse
          printf '%s\n' "$PULSE_ENV" > .env
          cat .env.defaults >> .env                      # compose interpolates only from .env
          echo "PULSE_API_TAG=$IMAGE_TAG" >> .env
          printf '%s\n' "$GCS_BACKUP_SA_JSON" > gcs-backup-sa.json
          set -a; . ./.env; set +a
          mountpoint -q "$(dirname "$PG_DATA")" || { echo "postgres volume not mounted at $PG_DATA"; exit 1; }
          docker compose pull -q && docker compose up -d
          for i in $(seq 1 30); do curl -sf localhost:8080/healthz | grep -q '"db":"ok"' && exit 0; sleep 2; done
          docker compose logs --tail 50 pulse-api; exit 1
      env:
        PULSE_ENV: ${{ secrets.PULSE_ENV }}
        GCS_BACKUP_SA_JSON: ${{ secrets.GCS_BACKUP_SA_JSON }}
        IMAGE_TAG: ${{ env.IMAGE_TAG }}

  terraform-apply:
    needs: [changes, terraform-plan]
    if: github.ref == 'refs/heads/main' && needs.changes.outputs.infra == 'true'
    runs-on: ubuntu-latest
    environment: production          # required reviewer = Anton → click to approve
    defaults: { run: { working-directory: infra/hetzner } }
    env:
      HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
      TF_VAR_cloudflare_zone_id: ${{ secrets.CLOUDFLARE_ZONE_ID }}
      TF_VAR_admin_cidr: ${{ secrets.ADMIN_CIDR }}
      TF_VAR_ssh_public_key: ${{ secrets.SSH_PUBLIC_KEY }}
    steps:
    - uses: actions/checkout@v6
    - uses: google-github-actions/auth@v3
      with: { credentials_json: "${{ secrets.GCP_CREDENTIALS }}" }
    - uses: hashicorp/setup-terraform@v3
      with: { terraform_version: "1.9.8" }
    - run: terraform init -input=false
    - run: terraform apply -auto-approve -input=false
```

Note the deploy-api host: on the *first* deploy DNS may not have propagated — the runbook (Task 8) does the first deploy by IP via `workflow_dispatch` after Terraform prints the IP, or simply waits for DNS.

- [ ] **Step 2: Validate and delete the old deploy workflow**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"
git rm -q .github/workflows/deploy.yml
```
Also add secrets `ADMIN_CIDR`, `SSH_PUBLIC_KEY` to the Inputs list (they are needed by both terraform jobs). Open the PR — the `changes` job should show `rust: true`, `api: true`, `infra: false` for this branch, and `swift` must **skip** (that's the path filter working).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows
git commit -m "ci: single path-filtered workflow with per-component deploys, terraform plan/apply"
```

### Task 6: Terraform `infra/hetzner` stack (box, volume, firewall, DNS, cloud-init)

**Files:**
- Create: `infra/hetzner/{versions.tf,backend.tf,variables.tf,main.tf,dns.tf,outputs.tf,cloud-init.yaml.tftpl}`, `infra/hetzner/files/{docker-compose.yml,Caddyfile,backup.sh}`, `infra/README.md`

**Interfaces:**
- Consumes: env `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`; vars `cloudflare_zone_id`, `admin_cidr`, `ssh_public_key`.
- Produces: outputs `server_ipv4`, `volume_mount`; DNS A records `api.eng-pulse.tsvetkov.org` and `eng-pulse.tsvetkov.org`; a box where `/opt/pulse/docker-compose.yml` runs caddy + pulse-api + postgres once `.env` exists.

- [ ] **Step 1: Bootstrap the state bucket (one-time, outside Terraform)**

```bash
gcloud storage buckets create gs://tsvet01-terraform-state --project tsvet01 --location us-central1 --uniform-bucket-level-access
gcloud storage buckets update gs://tsvet01-terraform-state --versioning
```

- [ ] **Step 2: Write the stack**

`versions.tf`:
```hcl
terraform {
  required_version = ">= 1.9"
  required_providers {
    hcloud     = { source = "hetznercloud/hcloud", version = "~> 1.50" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 4.52" }
  }
}
provider "hcloud" {}      # HCLOUD_TOKEN
provider "cloudflare" {}  # CLOUDFLARE_API_TOKEN
```

`backend.tf`:
```hcl
terraform {
  backend "gcs" {
    bucket = "tsvet01-terraform-state"
    prefix = "hetzner"
  }
}
```

`variables.tf`:
```hcl
variable "cloudflare_zone_id" { type = string }
variable "admin_cidr"         { type = string, description = "CIDR allowed to SSH (Anton's IP/32)" }
variable "ssh_public_key"     { type = string }
variable "server_type"        { type = string, default = "cx22" }
variable "location"           { type = string, default = "nbg1" }
variable "api_image"          { type = string, default = "ghcr.io/tsvet01/pulse-api" }
```

`main.tf`:
```hcl
resource "hcloud_ssh_key" "anton" {
  name       = "anton"
  public_key = var.ssh_public_key
}

resource "hcloud_firewall" "pulse" {
  name = "pulse"
  rule { direction = "in", protocol = "tcp", port = "22",  source_ips = [var.admin_cidr] }
  rule { direction = "in", protocol = "tcp", port = "80",  source_ips = ["0.0.0.0/0", "::/0"] }
  rule { direction = "in", protocol = "tcp", port = "443", source_ips = ["0.0.0.0/0", "::/0"] }
  rule { direction = "in", protocol = "icmp",             source_ips = ["0.0.0.0/0", "::/0"] }
}

resource "hcloud_primary_ip" "pulse" {
  name          = "pulse-ipv4"
  type          = "ipv4"
  assignee_type = "server"
  auto_delete   = false
  datacenter    = "${var.location}-dc3"
}

resource "hcloud_volume" "pg" {
  name     = "pulse-pg"
  size     = 10
  location = var.location
  format   = "ext4"
}

resource "hcloud_server" "pulse" {
  name         = "pulse"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.anton.id]
  firewall_ids = [hcloud_firewall.pulse.id]
  public_net {
    ipv4 = hcloud_primary_ip.pulse.id
  }
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_public_key = var.ssh_public_key
    api_image      = var.api_image
    volume_id      = hcloud_volume.pg.id
    compose        = file("${path.module}/files/docker-compose.yml")
    caddyfile      = file("${path.module}/files/Caddyfile")
    backup_sh      = file("${path.module}/files/backup.sh")
  })
}

resource "hcloud_volume_attachment" "pg" {
  volume_id = hcloud_volume.pg.id
  server_id = hcloud_server.pulse.id
  automount = true
}
```

`dns.tf`:
```hcl
resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = "api.eng-pulse"
  type    = "A"
  content = hcloud_primary_ip.pulse.ip_address
  ttl     = 300
  proxied = false
}

resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "eng-pulse"
  type    = "A"
  content = hcloud_primary_ip.pulse.ip_address
  ttl     = 300
  proxied = false
}
```

`outputs.tf`:
```hcl
output "server_ipv4"  { value = hcloud_primary_ip.pulse.ip_address }
output "volume_mount" { value = "/mnt/HC_Volume_${hcloud_volume.pg.id}" }
```

`cloud-init.yaml.tftpl`:
```yaml
#cloud-config
package_update: true
packages: [docker.io, docker-compose-v2, unattended-upgrades, curl, jq]
users:
  - name: deploy
    groups: [docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys: ["${ssh_public_key}"]
write_files:
  - path: /opt/pulse/docker-compose.yml
    content: |
      ${indent(6, compose)}
  - path: /opt/pulse/Caddyfile
    content: |
      ${indent(6, caddyfile)}
  - path: /opt/pulse/backup.sh
    permissions: "0755"
    content: |
      ${indent(6, backup_sh)}
  - path: /etc/systemd/system/pulse.service
    content: |
      [Unit]
      Description=Eng Pulse compose stack
      Requires=docker.service
      After=docker.service network-online.target
      RequiresMountsFor=/mnt/HC_Volume_${volume_id}

      [Service]
      Type=oneshot
      RemainAfterExit=true
      WorkingDirectory=/opt/pulse
      ExecStart=/usr/bin/docker compose up -d
      ExecStop=/usr/bin/docker compose down

      [Install]
      WantedBy=multi-user.target
  - path: /etc/cron.d/pulse-backup
    content: "15 3 * * * deploy /opt/pulse/backup.sh >> /var/log/pulse-backup.log 2>&1\n"
  - path: /opt/pulse/.env.defaults
    content: |
      PULSE_API_IMAGE=${api_image}
      PG_DATA=/mnt/HC_Volume_${volume_id}/postgres
runcmd:
  - chown -R deploy:deploy /opt/pulse
  - systemctl enable docker
  - systemctl daemon-reload
  - systemctl enable pulse.service
```

`files/docker-compose.yml`:
```yaml
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
  pulse-api:
    image: ${PULSE_API_IMAGE}:${PULSE_API_TAG:-latest}
    restart: unless-stopped
    env_file: .env
    environment:
      DATABASE_URL: postgres://pulse:${POSTGRES_PASSWORD}@postgres:5432/pulse
    ports: ["127.0.0.1:8080:8080"]
    depends_on:
      postgres: { condition: service_healthy }
  postgres:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_USER: pulse
      POSTGRES_DB: pulse
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes: ["${PG_DATA}:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U pulse"]
      interval: 5s
      timeout: 5s
      retries: 10
volumes:
  caddy_data:
```
(Compose interpolates `${…}` from `/opt/pulse/.env` only; the deploy job writes `.env` as `PULSE_ENV` + `.env.defaults` + `PULSE_API_TAG`, so `PULSE_API_IMAGE`/`PG_DATA` are always present. The systemd unit — written inline by cloud-init — requires the volume mount before starting the stack.)

`files/Caddyfile`:
```
api.eng-pulse.tsvetkov.org {
    reverse_proxy pulse-api:8080
}
eng-pulse.tsvetkov.org {
    respond "eng-pulse" 200
}
```

`files/backup.sh`:
```bash
#!/usr/bin/env bash
# Nightly pg_dump → private GCS bucket via rclone (SA key written by the deploy job). Keeps 30 days.
set -euo pipefail
cd /opt/pulse
set -a; . ./.env.defaults; . ./.env; set +a
STAMP=$(date -u +%F)
mkdir -p backups
docker compose exec -T postgres pg_dump -U pulse pulse | gzip > "backups/pulse-${STAMP}.sql.gz"
docker run --rm -v /opt/pulse/backups:/b -v /opt/pulse/gcs-backup-sa.json:/sa.json:ro rclone/rclone \
  --gcs-service-account-file /sa.json copy /b :gcs:tsvet01-pulse-backups/postgres
docker run --rm -v /opt/pulse/gcs-backup-sa.json:/sa.json:ro rclone/rclone \
  --gcs-service-account-file /sa.json delete --min-age 30d :gcs:tsvet01-pulse-backups/postgres
find backups -name '*.sql.gz' -mtime +3 -delete
```
Create the backups bucket once: `gcloud storage buckets create gs://tsvet01-pulse-backups --project tsvet01 --location us-central1 --uniform-bucket-level-access` and a service account with `roles/storage.objectAdmin` on it only (its JSON key is the `GCS_BACKUP_SA_JSON` secret).

`infra/README.md`: how to run locally (`export HCLOUD_TOKEN=… CLOUDFLARE_API_TOKEN=…`, `gcloud auth application-default login` for state, `terraform init && terraform plan`), the "Terraform provisions, CI deploys" rule, and the first-deploy runbook pointer (Task 8).

- [ ] **Step 3: Validate locally without credentials, then plan with them**

```bash
cd infra/hetzner && terraform fmt -recursive && terraform init -backend=false && terraform validate
# with Anton's tokens exported and TF_VAR_* set:
terraform init && terraform plan
```
Expected: `validate` succeeds; `plan` shows exactly: 1 ssh key, 1 firewall, 1 primary IP, 1 volume, 1 server, 1 attachment, 2 DNS records (8 to add, 0 to change/destroy).

- [ ] **Step 4: Commit**

```bash
git add infra
git commit -m "infra: Terraform Hetzner stack (cx22, volume, firewall, Cloudflare DNS, cloud-init compose host)"
```

### Task 7: Supabase project + GitHub environment setup (runbook, no code)

**Files:**
- Create: `docs/runbooks/phase0-setup.md`

- [ ] **Step 1: Write the runbook** with these exact sections:

1. **Supabase**: create project `eng-pulse` (region: EU Frankfurt, nearest to `nbg1`); Authentication → Providers: enable **Apple** (Services ID + key from Apple Developer, team `9XQ7BW6Q4T`), **Google** (OAuth client IDs for iOS and web), **Email** with magic link/OTP; Authentication → SMTP: Anton's SMTP creds (Gmail app password host `smtp.gmail.com:587`); note the project URL and the JWKS URL `https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json` and issuer `https://<project-ref>.supabase.co/auth/v1`.
2. **GitHub environment `production`** (Settings → Environments → New → required reviewers: Anton): secrets `HCLOUD_TOKEN`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ZONE_ID`, `ADMIN_CIDR`, `SSH_PUBLIC_KEY`, `DEPLOY_SSH_KEY`, `GCS_BACKUP_SA_JSON`, `PULSE_ENV`. Note: `terraform-plan` (PR job) reads `HCLOUD_TOKEN`/`CLOUDFLARE_*`/`ADMIN_CIDR`/`SSH_PUBLIC_KEY` as **repository** secrets (plans run on PRs, before approval) — set those at repository level too; the box-mutating ones (`DEPLOY_SSH_KEY`, `PULSE_ENV`, `GCS_BACKUP_SA_JSON`) live only in `production`.
3. **`PULSE_ENV` body** (exact keys the API and compose read):
```
POSTGRES_PASSWORD=<generate: openssl rand -hex 24>
BIND_ADDR=0.0.0.0:8080
RUST_LOG=info
SUPABASE_JWKS_URL=https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json
SUPABASE_ISSUER=https://<project-ref>.supabase.co/auth/v1
PIPELINE_SERVICE_TOKEN=<generate: openssl rand -hex 32>
```
(Only `POSTGRES_PASSWORD`/`BIND_ADDR`/`RUST_LOG` are read in Phase 0; the Supabase and service-token keys are consumed by Phase 1 — set them now so Phase 1 needs no environment change.)
4. **Cloudflare**: confirm `tsvetkov.org` nameservers are Cloudflare's (`dig NS tsvetkov.org`); create an API token with `Zone:DNS:Edit` scoped to the zone; copy the zone ID from the overview page.
5. **Hetzner**: project `eng-pulse` → Security → API tokens → Read & Write.

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/phase0-setup.md
git commit -m "docs: Phase 0 setup runbook (Supabase, GitHub environment, Cloudflare, Hetzner)"
```

### Task 8: First apply and end-to-end verification (runbook execution)

**Files:**
- Modify: `docs/runbooks/phase0-setup.md` (append "First deploy" section + the verification checklist with actual outputs)

- [ ] **Step 1: Apply infrastructure**

Merge the branch. On main, `terraform-plan` will have posted the 8-resource plan on the PR; `terraform-apply` waits for Anton's approval in the `production` environment → approve. Or locally: `cd infra/hetzner && terraform apply` with tokens exported. Record `server_ipv4`.

- [ ] **Step 2: First API deploy**

DNS-only records propagate within TTL (300s). Then trigger the workflow (`workflow_dispatch` on main, or re-run the `deploy-api` job) so the box receives `.env` and pulls the image. Verify from the runner logs that `/healthz` returned `"db":"ok"`.

- [ ] **Step 3: External verification (the real-run rule)**

```bash
curl -sv https://api.eng-pulse.tsvetkov.org/healthz 2>&1 | grep -E "subject:|issuer:|HTTP/|db"
ssh deploy@api.eng-pulse.tsvetkov.org 'cd /opt/pulse && docker compose ps && df -h /mnt/HC_Volume_* && sudo /opt/pulse/backup.sh && ls -la backups'
gcloud storage ls gs://tsvet01-pulse-backups/postgres/
```
Expected: valid Let's Encrypt cert for `api.eng-pulse.tsvetkov.org`, `HTTP/2 200`, `{"status":"ok","db":"ok"}`; three healthy containers; the volume mounted at the `PG_DATA` path; a `pulse-<date>.sql.gz` in the bucket.

- [ ] **Step 4: Also confirm nothing regressed on the GCP side**

The merge to main ran `deploy-agents` (workspace Dockerfiles) and its `--smoke` gate passed; next morning's 06:00 UTC run succeeds (`./scripts/shadow-eval-report.sh 1`).

- [ ] **Step 5: Commit the runbook addendum**

```bash
git add docs/runbooks/phase0-setup.md
git commit -m "docs: Phase 0 first-deploy verification record"
```
