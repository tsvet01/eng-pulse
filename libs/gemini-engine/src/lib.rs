use serde::{Deserialize, Serialize};
use tracing::{debug, error, warn, instrument};
use tracing_subscriber::{fmt, EnvFilter};
use backoff::{ExponentialBackoff, future::retry};
use std::time::Duration;
use url::Url;

const MAX_RETRY_ELAPSED_SECS: u64 = 120;

/// Default GCS bucket for storing agent data
pub const DEFAULT_BUCKET: &str = "tsvet01-agent-brain";

/// Default Gemini model to use
pub const DEFAULT_GEMINI_MODEL: &str = "gemini-3-pro-preview";

/// Default OpenAI model to use
pub const DEFAULT_OPENAI_MODEL: &str = "gpt-5.2-2025-12-11";

/// Default Claude model to use
pub const DEFAULT_CLAUDE_MODEL: &str = "claude-opus-4-5";

// Re-export for backwards compatibility
pub const DEFAULT_MODEL: &str = DEFAULT_GEMINI_MODEL;

/// Supported LLM providers
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LlmProvider {
    Gemini,
    OpenAI,
    Claude,
}

impl LlmProvider {
    pub fn as_str(&self) -> &'static str {
        match self {
            LlmProvider::Gemini => "gemini",
            LlmProvider::OpenAI => "openai",
            LlmProvider::Claude => "claude",
        }
    }

    pub fn display_name(&self) -> &'static str {
        match self {
            LlmProvider::Gemini => "Gemini",
            LlmProvider::OpenAI => "OpenAI",
            LlmProvider::Claude => "Claude",
        }
    }

    /// Returns the exact model name/ID used for this provider
    pub fn model_name(&self) -> &'static str {
        match self {
            LlmProvider::Gemini => DEFAULT_GEMINI_MODEL,
            LlmProvider::OpenAI => DEFAULT_OPENAI_MODEL,
            LlmProvider::Claude => DEFAULT_CLAUDE_MODEL,
        }
    }
}

// --- Shared Utilities ---

/// Extract the domain/host from a URL string safely.
/// Returns "unknown" if the URL cannot be parsed.
pub fn extract_domain(url: &str) -> String {
    Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|s| s.to_string()))
        .unwrap_or_else(|| "unknown".to_string())
}

// --- Shared Types ---

/// Configuration for a news/article source
#[derive(Deserialize, Serialize, Debug, Clone, PartialEq, Eq, Hash)]
pub struct SourceConfig {
    pub name: String,
    #[serde(rename = "type")]
    pub source_type: String,
    pub url: String,
}

// --- Shared Logging ---

/// Initialize structured logging with JSON format in production (when RUST_LOG is set),
/// or pretty format for local development.
pub fn init_logging() {
    let is_production = std::env::var("RUST_LOG").is_ok();

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"));

    if is_production {
        let _ = fmt()
            .with_env_filter(filter)
            .json()
            .with_target(true)
            .with_thread_ids(false)
            .with_file(true)
            .with_line_number(true)
            .try_init();
    } else {
        let _ = fmt()
            .with_env_filter(filter)
            .with_target(false)
            .try_init();
    }
}

// --- Gemini Structs ---
#[derive(Serialize, Deserialize, Debug)]
pub struct GeminiPart {
    pub text: String,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct GeminiContent {
    pub parts: Vec<GeminiPart>,
}

#[derive(Serialize, Debug)]
pub struct GeminiRequest {
    pub contents: Vec<GeminiContent>,
}

#[derive(Deserialize, Debug)]
pub struct GeminiCandidate {
    pub content: GeminiContent,
}

#[derive(Deserialize, Debug)]
pub struct GeminiResponse {
    pub candidates: Option<Vec<GeminiCandidate>>,
    pub error: Option<GeminiError>,
}

#[derive(Deserialize, Debug)]
pub struct GeminiError {
    pub message: String,
}

/// Call Gemini API with exponential backoff retry for transient failures
#[instrument(skip(client, api_key, prompt), fields(prompt_len = prompt.len()))]
pub async fn call_gemini_with_retry(
    client: &reqwest::Client,
    api_key: &str,
    prompt: String,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let backoff = ExponentialBackoff {
        max_elapsed_time: Some(Duration::from_secs(MAX_RETRY_ELAPSED_SECS)),
        ..Default::default()
    };

    let client = client.clone();
    let api_key = api_key.to_string();

    let result = retry(backoff, || {
        let client = client.clone();
        let api_key = api_key.clone();
        let prompt = prompt.clone();

        async move {
            match call_gemini(&client, &api_key, prompt).await {
                Ok(response) => Ok(response),
                Err(e) => {
                    let err_str = e.to_string();
                    // Retry on transient errors (network, rate limits, server errors)
                    if is_transient_error(&err_str) {
                        warn!(error = %err_str, "Transient Gemini error, retrying");
                        Err(backoff::Error::transient(e))
                    } else {
                        error!(error = %err_str, "Permanent Gemini error, not retrying");
                        Err(backoff::Error::permanent(e))
                    }
                }
            }
        }
    }).await?;

    Ok(result)
}

fn is_transient_error(err: &str) -> bool {
    let transient_patterns = [
        "timeout",
        "connection",
        "rate limit",
        "408",  // Request Timeout
        "429",  // Too Many Requests
        "500",
        "502",
        "503",
        "504",
        "temporarily",
        "overloaded",
    ];

    let err_lower = err.to_lowercase();
    transient_patterns.iter().any(|p| err_lower.contains(p))
}

async fn call_gemini(client: &reqwest::Client, api_key: &str, text: String) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    // Get model from environment or use default
    let model = std::env::var("GEMINI_MODEL").unwrap_or_else(|_| DEFAULT_MODEL.to_string());

    // Note: API key in URL is required by Gemini API - we redact it in logs
    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={}",
        model, api_key
    );

    let request = GeminiRequest {
        contents: vec![
            GeminiContent {
                parts: vec![ GeminiPart { text } ]
            }
        ]
    };

    debug!("Sending request to Gemini API");

    let res = client.post(&url)
        .json(&request)
        .send()
        .await?;

    let status = res.status();
    debug!(status = %status, "Gemini API response received");

    if !status.is_success() {
        let error_body = res.text().await.unwrap_or_default();
        return Err(format!("Gemini API returned {}: {}", status, error_body).into());
    }

    let resp: GeminiResponse = res.json().await?;

    if let Some(error) = resp.error {
        return Err(format!("Gemini API Error: {}", error.message).into());
    }

    if let Some(candidates) = resp.candidates {
        if let Some(first) = candidates.first() {
            if let Some(part) = first.content.parts.first() {
                return Ok(part.text.clone());
            }
        }
    }

    Err("No content returned from Gemini".into())
}

// --- OpenAI API ---

#[derive(Serialize, Debug)]
struct OpenAIMessage {
    role: String,
    content: String,
}

#[derive(Serialize, Debug)]
struct OpenAIRequest {
    model: String,
    messages: Vec<OpenAIMessage>,
}

#[derive(Deserialize, Debug)]
struct OpenAIChoice {
    message: OpenAIMessageResponse,
}

#[derive(Deserialize, Debug)]
struct OpenAIMessageResponse {
    content: String,
}

#[derive(Deserialize, Debug)]
struct OpenAIResponse {
    choices: Option<Vec<OpenAIChoice>>,
    error: Option<OpenAIError>,
}

#[derive(Deserialize, Debug)]
struct OpenAIError {
    message: String,
}

/// Call OpenAI API with exponential backoff retry for transient failures
#[instrument(skip(client, api_key, prompt), fields(prompt_len = prompt.len()))]
pub async fn call_openai_with_retry(
    client: &reqwest::Client,
    api_key: &str,
    prompt: String,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let backoff = ExponentialBackoff {
        max_elapsed_time: Some(Duration::from_secs(MAX_RETRY_ELAPSED_SECS)),
        ..Default::default()
    };

    let client = client.clone();
    let api_key = api_key.to_string();

    let result = retry(backoff, || {
        let client = client.clone();
        let api_key = api_key.clone();
        let prompt = prompt.clone();

        async move {
            match call_openai(&client, &api_key, prompt).await {
                Ok(response) => Ok(response),
                Err(e) => {
                    let err_str = e.to_string();
                    if is_transient_error(&err_str) {
                        warn!(error = %err_str, "Transient OpenAI error, retrying");
                        Err(backoff::Error::transient(e))
                    } else {
                        error!(error = %err_str, "Permanent OpenAI error, not retrying");
                        Err(backoff::Error::permanent(e))
                    }
                }
            }
        }
    }).await?;

    Ok(result)
}

async fn call_openai(client: &reqwest::Client, api_key: &str, text: String) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let model = std::env::var("OPENAI_MODEL").unwrap_or_else(|_| DEFAULT_OPENAI_MODEL.to_string());

    let request = OpenAIRequest {
        model,
        messages: vec![OpenAIMessage {
            role: "user".to_string(),
            content: text,
        }],
    };

    debug!("Sending request to OpenAI API");

    let res = client.post("https://api.openai.com/v1/chat/completions")
        .header("Authorization", format!("Bearer {}", api_key))
        .json(&request)
        .send()
        .await?;

    let status = res.status();
    debug!(status = %status, "OpenAI API response received");

    if !status.is_success() {
        let error_body = res.text().await.unwrap_or_default();
        return Err(format!("OpenAI API returned {}: {}", status, error_body).into());
    }

    let resp: OpenAIResponse = res.json().await?;

    if let Some(error) = resp.error {
        return Err(format!("OpenAI API Error: {}", error.message).into());
    }

    if let Some(choices) = resp.choices {
        if let Some(first) = choices.first() {
            return Ok(first.message.content.clone());
        }
    }

    Err("No content returned from OpenAI".into())
}

// --- Claude API ---

#[derive(Serialize, Debug)]
struct ClaudeMessage {
    role: String,
    content: String,
}

#[derive(Serialize, Debug)]
struct ClaudeRequest {
    model: String,
    max_tokens: u32,
    messages: Vec<ClaudeMessage>,
}

#[derive(Deserialize, Debug)]
struct ClaudeContentBlock {
    text: Option<String>,
}

#[derive(Deserialize, Debug)]
struct ClaudeResponse {
    content: Option<Vec<ClaudeContentBlock>>,
    error: Option<ClaudeError>,
}

#[derive(Deserialize, Debug)]
struct ClaudeError {
    message: String,
}

/// Call Claude API with exponential backoff retry for transient failures
#[instrument(skip(client, api_key, prompt), fields(prompt_len = prompt.len()))]
pub async fn call_claude_with_retry(
    client: &reqwest::Client,
    api_key: &str,
    prompt: String,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let backoff = ExponentialBackoff {
        max_elapsed_time: Some(Duration::from_secs(MAX_RETRY_ELAPSED_SECS)),
        ..Default::default()
    };

    let client = client.clone();
    let api_key = api_key.to_string();

    let result = retry(backoff, || {
        let client = client.clone();
        let api_key = api_key.clone();
        let prompt = prompt.clone();

        async move {
            match call_claude(&client, &api_key, prompt).await {
                Ok(response) => Ok(response),
                Err(e) => {
                    let err_str = e.to_string();
                    if is_transient_error(&err_str) {
                        warn!(error = %err_str, "Transient Claude error, retrying");
                        Err(backoff::Error::transient(e))
                    } else {
                        error!(error = %err_str, "Permanent Claude error, not retrying");
                        Err(backoff::Error::permanent(e))
                    }
                }
            }
        }
    }).await?;

    Ok(result)
}

async fn call_claude(client: &reqwest::Client, api_key: &str, text: String) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let model = std::env::var("CLAUDE_MODEL").unwrap_or_else(|_| DEFAULT_CLAUDE_MODEL.to_string());

    let request = ClaudeRequest {
        model,
        max_tokens: 4096,
        messages: vec![ClaudeMessage {
            role: "user".to_string(),
            content: text,
        }],
    };

    debug!("Sending request to Claude API");

    let res = client.post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&request)
        .send()
        .await?;

    let status = res.status();
    debug!(status = %status, "Claude API response received");

    if !status.is_success() {
        let error_body = res.text().await.unwrap_or_default();
        return Err(format!("Claude API returned {}: {}", status, error_body).into());
    }

    let resp: ClaudeResponse = res.json().await?;

    if let Some(error) = resp.error {
        return Err(format!("Claude API Error: {}", error.message).into());
    }

    if let Some(content) = resp.content {
        if let Some(block) = content.first() {
            if let Some(text) = &block.text {
                return Ok(text.clone());
            }
        }
    }

    Err("No content returned from Claude".into())
}

// --- Unified API ---

/// Call any LLM provider with exponential backoff retry
#[instrument(skip(client, api_key, prompt), fields(provider = %provider.as_str(), prompt_len = prompt.len()))]
pub async fn call_llm_with_retry(
    client: &reqwest::Client,
    provider: LlmProvider,
    api_key: &str,
    prompt: String,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    match provider {
        LlmProvider::Gemini => call_gemini_with_retry(client, api_key, prompt).await,
        LlmProvider::OpenAI => call_openai_with_retry(client, api_key, prompt).await,
        LlmProvider::Claude => call_claude_with_retry(client, api_key, prompt).await,
    }
}

/// Get the API key environment variable name for a provider
pub fn get_api_key_env_var(provider: LlmProvider) -> &'static str {
    match provider {
        LlmProvider::Gemini => "GEMINI_API_KEY",
        LlmProvider::OpenAI => "OPENAI_API_KEY",
        LlmProvider::Claude => "ANTHROPIC_API_KEY",
    }
}

/// Get the model environment variable name for a provider
pub fn get_model_env_var(provider: LlmProvider) -> &'static str {
    match provider {
        LlmProvider::Gemini => "GEMINI_MODEL",
        LlmProvider::OpenAI => "OPENAI_MODEL",
        LlmProvider::Claude => "CLAUDE_MODEL",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_transient_error_timeout() {
        assert!(is_transient_error("Connection timeout occurred"));
        assert!(is_transient_error("Request TIMEOUT"));
    }

    #[test]
    fn test_is_transient_error_rate_limit() {
        assert!(is_transient_error("Rate limit exceeded"));
        assert!(is_transient_error("HTTP 429 Too Many Requests"));
    }

    #[test]
    fn test_is_transient_error_server_errors() {
        assert!(is_transient_error("HTTP 408 Request Timeout"));
        assert!(is_transient_error("HTTP 500 Internal Server Error"));
        assert!(is_transient_error("502 Bad Gateway"));
        assert!(is_transient_error("503 Service Unavailable"));
        assert!(is_transient_error("504 Gateway Timeout"));
    }

    #[test]
    fn test_is_transient_error_connection() {
        assert!(is_transient_error("Connection refused"));
        assert!(is_transient_error("connection reset by peer"));
    }

    #[test]
    fn test_is_transient_error_overloaded() {
        assert!(is_transient_error("Server temporarily overloaded"));
        assert!(is_transient_error("Service is temporarily unavailable"));
    }

    #[test]
    fn test_is_not_transient_error() {
        assert!(!is_transient_error("Invalid API key"));
        assert!(!is_transient_error("Bad request: malformed JSON"));
        assert!(!is_transient_error("HTTP 400 Bad Request"));
        assert!(!is_transient_error("HTTP 401 Unauthorized"));
        assert!(!is_transient_error("HTTP 403 Forbidden"));
        assert!(!is_transient_error("HTTP 404 Not Found"));
    }

    #[test]
    fn test_gemini_request_serialization() {
        let request = GeminiRequest {
            contents: vec![GeminiContent {
                parts: vec![GeminiPart {
                    text: "Hello, Gemini!".to_string(),
                }],
            }],
        };

        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("Hello, Gemini!"));
        assert!(json.contains("contents"));
        assert!(json.contains("parts"));
        assert!(json.contains("text"));
    }

    #[test]
    fn test_gemini_response_deserialization_success() {
        let json = r#"{
            "candidates": [{
                "content": {
                    "parts": [{"text": "Hello from Gemini!"}]
                }
            }]
        }"#;

        let response: GeminiResponse = serde_json::from_str(json).unwrap();
        assert!(response.candidates.is_some());
        assert!(response.error.is_none());

        let candidates = response.candidates.unwrap();
        assert_eq!(candidates.len(), 1);
        assert_eq!(candidates[0].content.parts[0].text, "Hello from Gemini!");
    }

    #[test]
    fn test_gemini_response_deserialization_error() {
        let json = r#"{
            "error": {
                "message": "API key invalid"
            }
        }"#;

        let response: GeminiResponse = serde_json::from_str(json).unwrap();
        assert!(response.candidates.is_none());
        assert!(response.error.is_some());
        assert_eq!(response.error.unwrap().message, "API key invalid");
    }

    #[test]
    fn test_gemini_response_deserialization_empty() {
        let json = r#"{}"#;

        let response: GeminiResponse = serde_json::from_str(json).unwrap();
        assert!(response.candidates.is_none());
        assert!(response.error.is_none());
    }

    #[test]
    fn test_extract_domain_valid_url() {
        assert_eq!(extract_domain("https://example.com/path"), "example.com");
        assert_eq!(extract_domain("http://blog.example.org/article?id=1"), "blog.example.org");
        assert_eq!(extract_domain("https://sub.domain.co.uk/"), "sub.domain.co.uk");
    }

    #[test]
    fn test_extract_domain_invalid_url() {
        assert_eq!(extract_domain("not a url"), "unknown");
        assert_eq!(extract_domain(""), "unknown");
        assert_eq!(extract_domain("ftp://"), "unknown");
    }

    #[test]
    fn test_source_config_serialization() {
        let source = SourceConfig {
            name: "Test Blog".to_string(),
            source_type: "rss".to_string(),
            url: "https://example.com/feed".to_string(),
        };

        let json = serde_json::to_string(&source).unwrap();
        assert!(json.contains("Test Blog"));
        assert!(json.contains("rss"));
        assert!(json.contains("https://example.com/feed"));
    }

    #[test]
    fn test_source_config_deserialization() {
        let json = r#"{"name": "My Blog", "type": "rss", "url": "https://myblog.com/feed"}"#;
        let source: SourceConfig = serde_json::from_str(json).unwrap();

        assert_eq!(source.name, "My Blog");
        assert_eq!(source.source_type, "rss");
        assert_eq!(source.url, "https://myblog.com/feed");
    }
}