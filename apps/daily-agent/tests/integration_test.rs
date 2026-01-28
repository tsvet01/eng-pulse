use wiremock::{MockServer, Mock, ResponseTemplate};
use wiremock::matchers::{method, path};
use gemini_engine::{call_llm_with_retry, LlmProvider};
use std::time::Duration;
use reqwest::Client;

// We need to declare the module if we want to use fetcher, but fetcher is inside src/fetcher.rs
// and likely not public. 
// A common pattern in Rust binaries is to have a lib.rs that exports modules, 
// or use #[path] to include them, but integration tests (in tests/) compile as separate crates.
//
// For now, we will test the shared engine and the fetcher logic if possible.
// NOTE: To test `fetcher`, `apps/daily-agent` would need to be a lib or export it. 
// Let's check `apps/daily-agent/src/lib.rs` existence or `main.rs` structure.
//
// Since `apps/daily-agent` seems to be a binary crate (main.rs), we can't easily import `fetcher` 
// in `tests/`.
//
// However, we CAN test `gemini-engine` logic here since it IS a library.
// And we can demonstrate how we WOULD test fetcher if it were exposed.
//
// Actually, `apps/daily-agent/src/fetcher.rs` is mod fetcher in main.rs.
// To make it testable from `tests/`, we should probably move `fetcher.rs` to `libs/gemini-engine` 
// or make `daily-agent` a mixed lib/bin crate. 
// 
// For this task, I will focus on testing `gemini-engine`'s ability to be mocked, 
// which satisfies the "Mocked External APIs" requirement.

#[tokio::test]
async fn test_gemini_api_mocking() {
    // 1. Start Mock Server
    let mock_server = MockServer::start().await;

    // 2. Configure Mock Response
    let response_body = r#"{
        "candidates": [{
            "content": {
                "parts": [{ "text": "Mocked Gemini Response" }]
            }
        }]
    }"#;

    Mock::given(method("POST"))
        .and(path("/v1beta/models/gemini-pro:generateContent")) 
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::from_str::<serde_json::Value>(response_body).unwrap()))
        .mount(&mock_server)
        .await;

    // 3. Configure Environment to point to Mock Server
    std::env::set_var("GEMINI_BASE_URL", mock_server.uri());
    std::env::set_var("GEMINI_MODEL", "gemini-pro"); // Match the path above

    // 4. Create Client
    let client = Client::builder().timeout(Duration::from_secs(5)).build().unwrap();

    // 5. Call API
    let result = call_llm_with_retry(
        &client, 
        LlmProvider::Gemini, 
        "test-key", 
        "Hello".to_string()
    ).await;

    // 6. Verify
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), "Mocked Gemini Response");
}

#[tokio::test]
async fn test_openai_api_mocking() {
    let mock_server = MockServer::start().await;

    let response_body = r#"{
        "choices": [{
            "message": { "content": "Mocked OpenAI Response" }
        }]
    }"#;

    Mock::given(method("POST"))
        .and(path("/chat/completions"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::from_str::<serde_json::Value>(response_body).unwrap()))
        .mount(&mock_server)
        .await;

    std::env::set_var("OPENAI_BASE_URL", mock_server.uri());
    
    let client = Client::builder().build().unwrap();

    let result = call_llm_with_retry(
        &client, 
        LlmProvider::OpenAI, 
        "test-key", 
        "Hello".to_string()
    ).await;

    assert!(result.is_ok());
    assert_eq!(result.unwrap(), "Mocked OpenAI Response");
}

#[tokio::test]
async fn test_claude_api_mocking() {
    let mock_server = MockServer::start().await;

    let response_body = r#"{
        "content": [{ "text": "Mocked Claude Response" }]
    }"#;

    Mock::given(method("POST"))
        .and(path("/messages"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::from_str::<serde_json::Value>(response_body).unwrap()))
        .mount(&mock_server)
        .await;

    std::env::set_var("CLAUDE_BASE_URL", mock_server.uri());
    
    let client = Client::builder().build().unwrap();

    let result = call_llm_with_retry(
        &client, 
        LlmProvider::Claude, 
        "test-key", 
        "Hello".to_string()
    ).await;

    assert!(result.is_ok());
    assert_eq!(result.unwrap(), "Mocked Claude Response");
}
