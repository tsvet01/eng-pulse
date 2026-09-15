# llm-client

Thin HTTP client for the Claude Messages API and OpenAI Chat Completions, shared by the agents. No framework: `reqwest` plus exponential backoff on transient errors (timeouts, connection errors, 408/429/5xx; 120 s total), and one `LLM usage` log line per call with provider, model and token counts.

```rust
use llm_client::{call_llm, LlmOptions, LlmProvider};

let text = call_llm(&client, LlmProvider::Claude, &api_key, prompt, &LlmOptions {
    system: Some("...".into()),
    model: None,            // DEFAULT_CLAUDE_MODEL unless CLAUDE_MODEL is set
    max_tokens: Some(16_000),
    ..Default::default()
}).await?;
```

Defaults: `DEFAULT_CLAUDE_MODEL` `claude-opus-5`, `DEFAULT_OPENAI_MODEL` `gpt-6-astra` (the judge), `DEFAULT_BUCKET` `tsvet01-agent-brain`. Env overrides: `CLAUDE_MODEL`, `OPENAI_MODEL`, `CLAUDE_BASE_URL`, `OPENAI_BASE_URL` (tests point these at wiremock). `temperature` is never sent to either provider (Opus 4.7+ and gpt-6-astra reject it). OpenAI reasoning is set with `LlmOptions.effort` (`reasoning_effort`: `low|medium|high|xhigh|max`); `max_tokens` is sent as `max_completion_tokens` there and includes reasoning tokens. `init_logging()` emits JSON when `RUST_LOG` is set, pretty output otherwise.
