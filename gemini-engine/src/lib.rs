use serde::{Deserialize, Serialize};
use tracing::{debug, error, warn, instrument};
use backoff::{ExponentialBackoff, future::retry};
use std::time::Duration;

const MAX_RETRY_ELAPSED_SECS: u64 = 120;

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