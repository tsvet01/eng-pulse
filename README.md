# Eng Pulse

[![CI](https://github.com/tsvet01/eng-pulse/actions/workflows/ci.yml/badge.svg)](https://github.com/tsvet01/eng-pulse/actions/workflows/ci.yml)

One engineering article a day, turned into an Insight Brief, delivered to an iOS app with text-to-speech and CarPlay, email and push.

## What runs today

```
sources.json ─▶ daily-agent (06:00 UTC, Cloud Run Job) ─▶ GCS bucket ─▶ iOS app / email / APNs
                  select (Claude) · brief (Claude Opus 5) · judge (Gemini)
explorer-agent (weekly) ─▶ sources.json
```

- **daily-agent** picks one article (headline shortlist, then full-text pick), writes `summaries/v3/<date>.json` (Insight Brief), scores it with a Gemini judge into `eval-v3/<date>.json`, and appends one entry to `manifest.json`.
- **explorer-agent** validates candidate feeds (`config/user_candidates.json`), drops stale sources, asks the model for new ones.
- **functions/** (Python, Cloud Functions): email notifier, APNs/FCM token registration, feedback receiver.
- **apps/mobile-swift** reads `manifest.json` from the public bucket `tsvet01-agent-brain`.

## Where it is going

Multi-user with interest feeds: Supabase for identity, `apps/pulse-api` (Rust/axum + Postgres 18) on a Hetzner box provisioned by `infra/hetzner` (Terraform, Cloudflare DNS). Phase 0 is live: `https://api.eng-pulse.tsvetkov.org/healthz`. Design: `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md`. Android (Kotlin/Compose) comes after the API.

## Layout

| Path | What |
|---|---|
| `libs/llm-client` | Claude/Gemini client: retries, usage logging |
| `libs/pulse-core` | Contract types; fixtures in `docs/contracts/` (CI drift guard) |
| `apps/daily-agent`, `apps/explorer-agent` | Pipeline jobs |
| `apps/pulse-api` | API (`/healthz`, sqlx migrations) |
| `apps/mobile-swift` | iOS app |
| `functions/*` | Python cloud functions |
| `infra/hetzner` | Terraform for the API box |
| `docs/runbooks` | Setup and operations; `docs/superpowers` specs and plans |

## Develop

Rust 1.98, Python 3.12, Xcode for the app.

```
./scripts/validate.sh --quick     # fmt, clippy -D warnings, tests, fixtures drift
cargo test --workspace
for f in notifier apns-notifier fcm-tokens; do (cd functions/$f && python -m pytest test_main.py -q); done
```

Run the pipeline locally with `ANTHROPIC_API_KEY` and `GEMINI_API_KEY` set: `cargo run -p daily-agent -- --smoke` checks both providers without side effects; `cargo run -p daily-agent` does a real run against `GCS_BUCKET` (default `tsvet01-agent-brain`). The API: start Postgres 18, then `DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse cargo run -p pulse-api`.

## Deploy

One path-filtered workflow, `.github/workflows/ci.yml`. PRs run the checks for what changed. On `main`: `deploy-agents` (Cloud Build → Cloud Run Jobs, then a `--smoke` run), `deploy-functions`, `terraform-apply` and `deploy-api` (GHCR image → SSH to the box), the last two behind the `production` environment approval. Manual API deploy: run the workflow with `deploy_api=true`.

Secrets live in GCP Secret Manager (pipeline) and GitHub environments (Hetzner); none in the repo. First-time setup: `docs/runbooks/phase0-setup.md`. Cloud agents: `docs/runbooks/cloud-agents.md`.

## Operations

- Schedules: daily 06:00 UTC, explorer Sundays 08:00 UTC (Cloud Scheduler).
- Alerts: job failure, "no summary in 25h", fatal-error log match (`scripts/setup-monitoring.sh`).
- Model changes are verified with a real run; the shadow lane (`SHADOW_MODEL`) compares a candidate model against production with a pairwise judge (`scripts/shadow-eval-report.sh N`).
- Postgres backups: nightly `pg_dump` from the box to `gs://tsvet01-pulse-backups`.

## License

MIT
