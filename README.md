# Eng Pulse

[![CI](https://github.com/tsvet01/eng-pulse/actions/workflows/ci.yml/badge.svg)](https://github.com/tsvet01/eng-pulse/actions/workflows/ci.yml)

One engineering article a day, turned into an Insight Brief, delivered to an iOS app with text-to-speech and CarPlay, email and push.

## What runs today

```
sources.json ─▶ daily-agent (06:00 UTC, Cloud Run Job) ─▶ GCS bucket ─▶ iOS app / email / APNs
                  select (Claude) · brief (Claude Opus 5) · judge (GPT-6 Astra)
explorer-agent (weekly) ─▶ sources.json
```

- **daily-agent** picks one article (headline shortlist, then full-text pick), writes `summaries/v3/<date>.json` (Insight Brief), scores it with a GPT-6 Astra judge into `eval-v3/<date>.json`, and appends one entry to `manifest.json`.
- **explorer-agent** validates candidate feeds (`config/user_candidates.json`), drops stale sources, asks the model for new ones.
- **functions/** (Python, Cloud Functions): email notifier, APNs/FCM token registration, feedback receiver.
- **apps/mobile-swift** reads `manifest.json` from the public bucket `tsvet01-agent-brain`.

## Where it is going

Next: a pilot for about five invited iOS users on the shared engineering feed, using Supabase identity and `pulse-api` (Rust/axum + Postgres) on Hetzner. The infrastructure health endpoint is live; the API MVP in [PR #185](https://github.com/tsvet01/eng-pulse/pull/185) and the app/notification launch gates still need completion. Keep the GCP daily/explorer pipeline and GCS artifacts throughout the pilot. Invitations follow working sign-in, account-safe offline reading/feedback, reliable email/APNs, and a tested recovery path. Extra feeds and Android follow a 14-day pilot review; OMGifts cleanup is separate. See the [active pilot plan](docs/superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md) and [revised design](docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md).

## Layout

| Path | What |
|---|---|
| `libs/llm-client` | Claude/OpenAI/Gemini client: retries, usage logging (pipeline uses Claude + OpenAI) |
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

Run the pipeline locally with `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` set: `cargo run -p se-daily-agent -- --smoke` checks both providers without side effects; `cargo run -p se-daily-agent` does a real run against `GCS_BUCKET` (default `tsvet01-agent-brain`). The API: start Postgres 18, then `DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse cargo run -p pulse-api`.

## Deploy

One path-filtered workflow, `.github/workflows/ci.yml`. PRs run the checks for what changed. On `main`: `deploy-agents` (Cloud Build → Cloud Run Jobs, then a `--smoke` run), `deploy-functions`, `terraform-apply` and `deploy-api` (GHCR image → SSH to the box), the last two behind the `production` environment approval. Manual API deploy: run the workflow with `deploy_api=true`.

Secrets live in GCP Secret Manager (pipeline) and GitHub environments (Hetzner); none in the repo. First-time setup: `docs/runbooks/phase0-setup.md`. Cloud agents: `docs/runbooks/cloud-agents.md`.

## Operations

- Schedules: daily 06:00 UTC, explorer Sundays 08:00 UTC (Cloud Scheduler).
- Alerts: job failure, "no summary in 25h", fatal-error log match (`scripts/setup-monitoring.sh`).
- Model changes are verified with a real run. The shadow lane uses `SHADOW_MODEL=gpt-6-astra` with high reasoning; Claude remains the published brief. Shadow failures warn and do not replace the production brief.
- After merging and CI deployment, the next 06:00 UTC run generates both briefs from the same article and prompt. Compare `summaries/v3/<date>.json` (Claude) with `summaries/v3-shadow/<date>.json` (Astra) in the public `tsvet01-agent-brain` GCS bucket. Shadow briefs do not appear in the app.
- Run `scripts/shadow-eval-report.sh 7` for pairwise results. Reports before this deployment refer to the previous shadow model. The Astra judge also scores Astra's candidate, so manually compare faithfulness, useful technical detail, and action quality before promotion.
- Postgres backups: nightly `pg_dump` from the box to `gs://tsvet01-pulse-backups`.

## License

MIT
