# Eng Pulse

Daily engineering brief. A Rust pipeline on GCP (Cloud Run Jobs, 06:00 UTC) picks one article from `config/sources.json`, writes a V3 Insight Brief to the public GCS bucket `tsvet01-agent-brain`, judges it with OpenAI GPT-6 Astra (`gpt-6-astra`), and notifies by email/APNs. The Swift iOS app reads the bucket. In progress: multi-user API (`apps/pulse-api`, axum + Postgres) on a Hetzner box managed by `infra/hetzner`; spec in `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md`. Production model: `claude-opus-5`. Env keys: `ANTHROPIC_API_KEY` (selection + brief), `OPENAI_API_KEY` (judge). Providers available in `libs/llm-client`: Claude, OpenAI, Gemini (unused today).

| Path | What |
|---|---|
| `libs/llm-client` | Claude/OpenAI/Gemini client, retries, usage logging |
| `libs/pulse-core` | Contract types; fixtures in `docs/contracts/` |
| `apps/daily-agent`, `apps/explorer-agent` | Pipeline jobs |
| `apps/pulse-api` | API: auth, feeds, briefs, devices; `/internal` for the pipeline |
| `apps/mobile-swift` | iOS app; builds on macOS only |
| `functions/*` | Python cloud functions |
| `infra/hetzner` | Terraform; applied by CI after human approval |
| `docs/runbooks` | Procedures |

## Commands

```
./scripts/validate.sh --quick        # fmt, clippy -D warnings, tests, fixtures drift
cargo test --workspace
cargo run -p pulse-core --bin fixtures && git diff --exit-code docs/contracts
for f in notifier apns-notifier fcm-tokens; do (cd functions/$f && python -m pytest test_main.py -q); done
```

pulse-api against Postgres 18: `DATABASE_URL=postgres://pulse:pulse@localhost:5432/pulse cargo run -p pulse-api`, then `curl localhost:8080/healthz`.

## Rules

- No secrets, keys, plist configs or credentials in git.
- Comments short and general.
- Pipeline behavior (prompts, selection, bucket layout, schedule) changes only on request.
- A model ID change needs a real job run after deploy.
- Agents never deploy, apply Terraform, or touch GCP/Hetzner; CI does on merge to `main`.
- Regenerate `docs/contracts/*.json`; never hand-edit.
- Small PRs.

## Code Review Rules

- Flag credentials or secret-bearing config.
- Flag selection/prompt changes in `apps/daily-agent` without a test or eval note.
- Flag unpinned GitHub Actions and new world-open firewall rules.
- Missing tests over style nits; rustfmt and clippy are enforced by CI.
