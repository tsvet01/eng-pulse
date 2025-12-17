use serde::{Deserialize, Serialize};
use tracing::{debug, error, warn, instrument};
use tracing_subscriber::{fmt, EnvFilter};
use backoff::{ExponentialBackoff, future::retry};
use std::time::Duration;
use url::Url;

const MAX_RETRY_ELAPSED_SECS: u64 = 120;

/// Default GCS bucket for storing agent data
pub const DEFAULT_BUCKET: &str = "tsvet01-agent-brain";

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
        "429",
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
    // Note: API key in URL is required by Gemini API - we redact it in logs
    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key={}",
        api_key
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
}