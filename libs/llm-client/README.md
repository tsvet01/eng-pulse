# Gemini Engine

Shared Rust crate providing a robust Gemini API client with exponential backoff retry logic.

> Part of [Eng Pulse](../../README.md) - see root README for system overview.

## Features

- **Exponential Backoff**: Automatic retry with configurable max elapsed time (default: 120s)
- **Transient Error Detection**: Intelligently distinguishes retryable errors from permanent failures
- **Structured Logging**: Uses `tracing` for observability
- **Type-safe API**: Strongly typed request/response structures

## Usage

Add to your `Cargo.toml`:

```toml
[dependencies]
gemini-engine = { path = "../../libs/gemini-engine" }
```

### Basic Example

```rust
use gemini_engine::call_gemini_with_retry;
use reqwest::Client;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::new();
    let api_key = std::env::var("GEMINI_API_KEY")?;

    let response = call_gemini_with_retry(
        &client,
        &api_key,
        "Summarize this article in 3 sentences.".to_string(),
    ).await?;

    println!("{}", response);
    Ok(())
}
```

## API

### `call_gemini_with_retry`

```rust
pub async fn call_gemini_with_retry(
    client: &reqwest::Client,
    api_key: &str,
    prompt: String,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>>
```

Makes a request to the Gemini API with automatic retry on transient failures.

**Parameters:**
- `client`: Shared reqwest client (for connection pooling)
- `api_key`: Gemini API key
- `prompt`: Text prompt to send to Gemini

**Returns:** Generated text response or error

**Retries on:**
- HTTP 429 (Rate Limit)
- HTTP 500, 502, 503, 504 (Server Errors)
- Connection timeouts
- Temporary network failures

**Does NOT retry on:**
- HTTP 400 (Bad Request)
- HTTP 401/403 (Auth Errors)
- Invalid API key
- Malformed requests

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GEMINI_MODEL` | `gemini-2.0-flash` | Gemini model to use |

### Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_RETRY_ELAPSED_SECS` | 120 | Maximum total retry time |
| `DEFAULT_MODEL` | `gemini-2.0-flash` | Default Gemini model |
| `DEFAULT_BUCKET` | `tsvet01-agent-brain` | Default GCS bucket |

## Data Structures

```rust
// Request structure
pub struct GeminiRequest {
    pub contents: Vec<GeminiContent>,
}

pub struct GeminiContent {
    pub parts: Vec<GeminiPart>,
}

pub struct GeminiPart {
    pub text: String,
}

// Response structure
pub struct GeminiResponse {
    pub candidates: Option<Vec<GeminiCandidate>>,
    pub error: Option<GeminiError>,
}
```

## Model

Uses `gemini-2.0-flash` by default. Override with `GEMINI_MODEL` environment variable:

```bash
export GEMINI_MODEL=gemini-1.5-pro
```

## Utility Functions

### `init_logging()`

Initializes structured logging with `tracing`:

```rust
use gemini_engine::init_logging;

fn main() {
    init_logging();
    // Logs now available
}
```

### `extract_domain(url)`

Extracts domain from URL for logging:

```rust
use gemini_engine::extract_domain;

let domain = extract_domain("https://blog.example.com/post/123");
// Returns "blog.example.com"
```

## Dependencies

- `reqwest` - HTTP client
- `serde` / `serde_json` - Serialization
- `tracing` - Logging
- `backoff` - Retry logic
- `tokio` - Async runtime
