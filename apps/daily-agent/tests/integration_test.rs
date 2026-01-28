use wiremock::{MockServer, Mock, ResponseTemplate};
use wiremock::matchers::{method, path};
use gemini_engine::{call_llm_with_retry, LlmProvider};
use std::time::Duration;
use reqwest::Client;

/// Helper to setup a mock server and run a test for a specific provider
async fn test_provider_mock(
    provider: LlmProvider,
    mock_path: &str,
    mock_response_body: serde_json::Value,
    base_url_env_var: &str,
    extra_env_setup: Option<(&str, &str)>,
) {
    // 1. Start Mock Server
    let mock_server = MockServer::start().await;

    // 2. Configure Mock Response
    Mock::given(method("POST"))
        .and(path(mock_path))
        .respond_with(ResponseTemplate::new(200).set_body_json(mock_response_body))
        .mount(&mock_server)
        .await;

    // 3. Configure Environment
    std::env::set_var(base_url_env_var, mock_server.uri());
    if let Some((key, value)) = extra_env_setup {
        std::env::set_var(key, value);
    }

    // 4. Create Client
    let client = Client::builder().timeout(Duration::from_secs(5)).build().unwrap();

    // 5. Call API
    let result = call_llm_with_retry(
        &client, 
        provider, 
        "test-key", 
        "Hello".to_string()
    ).await;

    // 6. Verify
    assert!(result.is_ok());
    let expected_response = match provider {
        LlmProvider::Gemini => "Mocked Gemini Response",
        LlmProvider::OpenAI => "Mocked OpenAI Response",
        LlmProvider::Claude => "Mocked Claude Response",
    };
    assert_eq!(result.unwrap(), expected_response);
}

#[tokio::test]
async fn test_gemini_api_mocking() {
    let response = serde_json::json!({
        "candidates": [{
            "content": {
                "parts": [{ "text": "Mocked Gemini Response" }]
            }
        }]
    });

    test_provider_mock(
        LlmProvider::Gemini,
        "/v1beta/models/gemini-pro:generateContent",
        response,
        "GEMINI_BASE_URL",
        Some(("GEMINI_MODEL", "gemini-pro"))
    ).await;
}

#[tokio::test]
async fn test_openai_api_mocking() {
    let response = serde_json::json!({
        "choices": [{
            "message": { "content": "Mocked OpenAI Response" }
        }]
    });

    test_provider_mock(
        LlmProvider::OpenAI,
        "/chat/completions",
        response,
        "OPENAI_BASE_URL",
        None
    ).await;
}

#[tokio::test]
async fn test_claude_api_mocking() {
    let response = serde_json::json!({
        "content": [{ "text": "Mocked Claude Response" }]
    });

    test_provider_mock(
        LlmProvider::Claude,
        "/messages",
        response,
        "CLAUDE_BASE_URL",
        None
    ).await;
}