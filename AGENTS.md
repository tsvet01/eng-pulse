# Eng Pulse — agent guide

Read by Codex (root `AGENTS.md`) and Claude Code (`CLAUDE.md` imports this file). Keep it short and current.

## What this is

A daily engineering brief. A Rust pipeline on GCP (Cloud Run Jobs, 06:00 UTC) selects one article from `config/sources.json`, writes a V3 Insight Brief plus legacy V1 summaries to the public GCS bucket `tsvet01-agent-brain`, judges it with Gemini, and notifies via email/APNs. The Swift iOS app reads the bucket. A multi-user rewrite is in progress per `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md`: `apps/pulse-api` (axum + Postgres) on a Hetzner box managed by `infra/hetzner` (Terraform). Production Claude model: `claude-opus-5` (`libs/llm-client`).

## Layout

| Path | What |
|---|---|
| `libs/llm-client` | Claude/Gemini HTTP client, retries, usage logging |
| `libs/pulse-core` | Shared contract types; fixtures in `docs/contracts/` |
| `apps/daily-agent`, `apps/explorer-agent` | The pipeline (Cloud Run Jobs) |
| `apps/pulse-api` | New API skeleton (`/healthz`, sqlx migrations) |
| `apps/mobile-swift` | iOS app (macOS/Xcode only; cannot build in Linux sandboxes) |
| `functions/*` | Python cloud functions (notifier, feedback, tokens) |
| `infra/hetzner` | Terraform for the API box; applied only by CI with approval |
| `docs/runbooks` | Operational procedures; `docs/superpowers` specs and plans |

## Commands (run from the repo root)

```
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo run -p pulse-core --bin fixtures && git diff --exit-code docs/contracts   # contract drift guard
./scripts/validate.sh --quick                                                  # all of the above
for f in notifier apns-notifier fcm-tokens; do (cd functions/$f && python -m pytest test_main.py -q); done
```

`apps/pulse-api` integration: start Postgres 16, then `DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse cargo run -p pulse-api` and `curl localhost:8080/healthz` → `{"status":"ok","db":"ok"}`.

## Rules

- Never commit secrets, API keys, plist configs, or credentials. `.env*`, `*.tfvars`, `tfplan` stay untracked.
- Comments are short and general; examples and war stories go in PR bodies.
- Pipeline behavior (prompts, selection, bucket layout, schedule) changes only when the task asks for it.
- Model IDs are API contracts: a model bump needs a real job run after deploy, not just green tests.
- Do not deploy, run `terraform apply`, or touch GCP/Hetzner from an agent session. CI deploys on merge to `main`; infra applies need a human approval.
- Do not hand-edit `docs/contracts/*.json`; regenerate with the fixtures binary.
- Small, focused PRs. CI is path-filtered (`.github/workflows/ci.yml`); a PR touching only docs runs nothing heavy.
- `docs/AGENTS.md` is the older, longer guide; parts of it predate the current architecture. This file wins on conflict.

## Code Review Rules

- Flag any credential, token, or config file with secrets.
- Flag changes to `apps/daily-agent` selection/prompt logic that lack a test or an eval note.
- Flag unpinned third-party GitHub Actions and any new world-open firewall rule.
- Prefer pointing out a missing test over style nits; rustfmt and clippy are enforced by CI.
