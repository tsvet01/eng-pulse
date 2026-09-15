# explorer-agent

Runs weekly (Cloud Run Job, Sundays 08:00 UTC). Maintains `config/sources.json` in the bucket:

1. Validates entries from `config/user_candidates.json` (`[{"name","type","url"}]`): discovers the RSS/Atom feed (direct URL, `<link rel=alternate>`, common suffixes), checks a 4 KB sample for relevance with Claude Haiku, then deletes the candidates file.
2. Asks Claude for new source recommendations and validates them the same way.
3. Drops sources with no post in 90 days.

```
cargo run -p explorer-agent
cargo test -p explorer-agent
```

| Env | Required | Default |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes | |
| `GCS_BUCKET` | no | `tsvet01-agent-brain` |
| `CLAUDE_MODEL` | no | recommendation model, see `libs/llm-client` |
| `RUST_LOG` | no | `info` |

Constants in `src/main.rs`: `FRESHNESS_DAYS` 90, `MAX_FEED_DISCOVERY_ATTEMPTS` 2, `MAX_RELEVANCE_SAMPLE_BYTES` 4096, `RELEVANCE_MODEL` `claude-haiku-4-5`. Deployed from CI on merge to `main`. To add sources by hand, upload a candidates file and run the job: `gcloud run jobs execute se-explorer-agent-job --region us-central1`.
