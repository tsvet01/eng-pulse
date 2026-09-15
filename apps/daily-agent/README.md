# daily-agent

Runs once a day (Cloud Run Job, 06:00 UTC). Loads `config/sources.json`, fetches recent articles, shortlists by headline then picks one by content (Claude), writes the V3 Insight Brief to `summaries/v3/<date>.json`, scores it with a GPT-6 Astra judge (`gpt-6-astra`, OpenAI) into `eval-v3/<date>.json`, and appends one entry to `manifest.json`.

```
cargo run -p se-daily-agent               # real run against GCS_BUCKET
cargo run -p se-daily-agent -- --smoke    # one tiny call per provider, no side effects (deploy gate)
cargo run -p se-daily-agent -- --date 2026-09-10   # backfill one day
cargo test -p se-daily-agent
```

| Env | Required | Default |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes | |
| `OPENAI_API_KEY` | yes (judge) | |
| `GCS_BUCKET` | no | `tsvet01-agent-brain` |
| `CLAUDE_MODEL`, `OPENAI_MODEL` | no | see `libs/llm-client` |
| `SHADOW_MODEL` | no | unset; when set, a second brief is generated with that model and judged pairwise against production (`eval-v3` gets `pairwise_winner`) |
| `RUST_LOG` | no | `info` |

Limits: articles under 200 chars are skipped, over 50,000 chars are truncated; HTTP timeout 60 s. Prompts live in `src/prompts.rs`; their wording is a tuned production artifact, change it only with an eval note. Deploy happens from CI on merge to `main` (`deploy-agents`), which also runs the smoke gate.
