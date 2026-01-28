mod fetcher;

use serde::{Deserialize, Serialize};

/// Parse an index from Gemini's response, extracting the first contiguous digit sequence.
/// Returns None if no valid number is found.
fn parse_selection_index(response: &str) -> Option<usize> {
    let digits: String = response
        .trim()
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit())
        .collect();

    if digits.is_empty() {
        None
    } else {
        digits.parse().ok()
    }
}
use readability::extractor;
use std::io::Cursor;
use crate::fetcher::{SourceConfig, Article};
use google_cloud_storage::client::{Client, ClientConfig};
use google_cloud_storage::http::objects::download::Range;
use google_cloud_storage::http::objects::get::GetObjectRequest;
use google_cloud_storage::http::objects::upload::{UploadObjectRequest, UploadType, Media};
use chrono::Utc;
use tracing::{info, warn, error, debug, instrument};
use std::time::Duration;
use gemini_engine::{
    call_llm_with_retry, init_logging, extract_domain,
    DEFAULT_BUCKET, LlmProvider, get_api_key_env_var,
};

// --- Configuration Constants ---
const HTTP_TIMEOUT_SECS: u64 = 60;
const MAX_ARTICLE_CHARS: usize = 50_000;
const SUMMARY_SNIPPET_CHARS: usize = 100;

// --- Manifest Struct ---
#[derive(Serialize, Deserialize, Debug, Clone)]
struct ManifestEntry {
    date: String,
    url: String,
    title: String,
    summary_snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    original_url: Option<String>,
    /// Which model generated the summary
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    /// Which model selected this article from the candidates
    #[serde(skip_serializing_if = "Option::is_none")]
    selected_by: Option<String>,
}

/// Get list of enabled LLM providers based on available API keys.
/// Claude is first for article selection, others follow for summary generation.
fn get_enabled_providers() -> Vec<(LlmProvider, String)> {
    let providers = [LlmProvider::Claude, LlmProvider::Gemini, LlmProvider::OpenAI];
    let mut enabled = Vec::new();

    for provider in providers {
        let env_var = get_api_key_env_var(provider);
        if let Ok(key) = std::env::var(env_var) {
            if !key.is_empty() {
                info!(provider = %provider.as_str(), "Provider enabled");
                enabled.push((provider, key));
            }
        }
    }

    enabled
}

// --- Main ---

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    dotenvy::dotenv().ok();
    init_logging();

    let bucket_name = std::env::var("GCS_BUCKET").unwrap_or_else(|_| DEFAULT_BUCKET.to_string());

    // Get enabled providers
    let enabled_providers = get_enabled_providers();
    if enabled_providers.is_empty() {
        error!("No LLM providers configured. Set at least one of: GEMINI_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY");
        return Err("No LLM providers configured".into());
    }

    info!(
        bucket = %bucket_name,
        providers = ?enabled_providers.iter().map(|(p, _)| p.as_str()).collect::<Vec<_>>(),
        "Starting SE Daily Agent"
    );

    // Use first provider for article selection (Claude preferred)
    let (selection_provider, selection_key) = enabled_providers.first().unwrap().clone();

    // 0. Initialize shared HTTP client (reused for connection pooling)
    let http_client = reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()?;

    // Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);

    // 1. Load Sources from GCS
    info!("Fetching sources.json from GCS");
    let sources_data = gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: "config/sources.json".to_string(),
            ..Default::default()
        },
        &Range::default()
    ).await?;

    let sources: Vec<SourceConfig> = serde_json::from_slice(&sources_data)?;
    info!(count = sources.len(), "Loaded sources from Cloud Storage");

    // 2. Fetch Articles (use a dedicated client for fetching with appropriate timeout)
    let fetch_client = fetcher::create_http_client()?;
    info!("Fetching headlines from sources");
    let mut all_articles: Vec<Article> = Vec::new();
    for source in sources {
        debug!(source = %source.name, "Fetching from source");
        match fetcher::fetch_from_source(&source, &fetch_client).await {
            Ok(mut articles) => {
                info!(source = %source.name, count = articles.len(), "Found articles");
                all_articles.append(&mut articles);
            },
            Err(e) => warn!(source = %source.name, error = %e, "Failed to fetch from source"),
        }
    }

    if all_articles.is_empty() {
        warn!("No recent articles found from any source");
        return Ok(());
    }

    info!(total_articles = all_articles.len(), "Total articles collected");

    // 3. Selection (using first available provider)
    info!(provider = %selection_provider.as_str(), "Asking LLM to select best article");

    let mut articles_text = String::new();
    for (i, article) in all_articles.iter().enumerate() {
        articles_text.push_str(&format!("{}. [{}] {}\n", i, article.source, article.title));
    }

    let selection_prompt = format!(
        "You are an expert Software Engineering Editor. Review the following list of article headlines collected today. Select the SINGLE most valuable, educational, and impactful article for a senior software engineer to read. Consider technical depth, novelty, and broad relevance.\n\n{}\n\nReply ONLY with the integer index number of the chosen article (e.g., '3'). Do not add any explanation.",
        articles_text
    );

    let selected_index = call_llm_with_retry(&http_client, selection_provider, &selection_key, selection_prompt).await?;

    // Parse the index using our helper function
    let index = parse_selection_index(&selected_index).ok_or_else(|| {
        format!("Failed to parse LLM selection '{}': no valid number found", selected_index.trim())
    })?;

    // Validate index is within bounds (all_articles cannot be empty - we return early above)
    let safe_index = if index >= all_articles.len() {
        warn!(
            returned_index = index,
            total_articles = all_articles.len(),
            provider = %selection_provider.as_str(),
            "LLM returned invalid index, using first article"
        );
        0
    } else {
        index
    };
    let best_article = &all_articles[safe_index];

    info!(
        title = %best_article.title,
        url = %best_article.url,
        source = %best_article.source,
        "Selected best article"
    );

    // 4. Fetch article content once (shared across all providers)
    info!("Scraping article content");

    let article_text = match fetch_article_content(&http_client, &best_article.url).await {
        Ok(content) => content,
        Err(e) => {
            warn!(error = %e, "Failed to fetch article content, using title only");
            format!("Title: {}, URL: {}", best_article.title, best_article.url)
        }
    };

    // Truncate safely at character boundary to avoid UTF-8 split
    let truncated_text: String = article_text.chars().take(MAX_ARTICLE_CHARS).collect();
    debug!(char_count = truncated_text.len(), "Article text truncated");

    let summary_prompt = format!(
        "Please summarize the following software engineering article in a compact and educational format. Focus on key takeaways, core concepts, and why it matters to a software engineer. Ignore any promotional or fluff content.\n\nArticle Source: {}\nTitle: {}\nContent: {}",
        best_article.source, best_article.title, truncated_text
    );

    // 5. Generate summaries with each enabled provider
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let mut new_manifest_entries: Vec<ManifestEntry> = Vec::new();

    for (provider, api_key) in &enabled_providers {
        info!(provider = %provider.as_str(), "Generating summary");

        match call_llm_with_retry(&http_client, *provider, api_key, summary_prompt.clone()).await {
            Ok(summary) => {
                info!(provider = %provider.as_str(), "Summary generated successfully");
                debug!(provider = %provider.as_str(), summary_length = summary.len(), "Summary details");

                // Create snippet BEFORE modifying summary
                let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();

                // Append metadata footer with original link
                let summary_with_footer = format!(
                    "{}\n\n---\n\n**Original article:** [{}]({})\n\n*Summarized by {} · Selected by {}*",
                    summary,
                    best_article.title,
                    best_article.url,
                    provider.model_name(),
                    selection_provider.model_name()
                );

                // Upload Summary to GCS (provider-specific path)
                let object_name = format!("summaries/{}/{}.md", provider.as_str(), today);
                let summary_bytes = summary_with_footer.into_bytes();

                info!(provider = %provider.as_str(), object = %object_name, "Uploading summary to GCS");

                let upload_type = UploadType::Simple(Media::new(object_name.clone()));
                match gcs_client.upload_object(
                    &UploadObjectRequest {
                        bucket: bucket_name.to_string(),
                        ..Default::default()
                    },
                    summary_bytes,
                    &upload_type
                ).await {
                    Ok(_) => {
                        info!(provider = %provider.as_str(), "Summary upload complete");

                        let public_url = format!("https://storage.googleapis.com/{}/{}", bucket_name, object_name);
                        new_manifest_entries.push(ManifestEntry {
                            date: today.clone(),
                            url: public_url,
                            title: best_article.title.clone(),
                            summary_snippet,
                            original_url: Some(best_article.url.clone()),
                            model: Some(provider.model_name().to_string()),
                            selected_by: Some(selection_provider.model_name().to_string()),
                        });
                    }
                    Err(e) => {
                        error!(provider = %provider.as_str(), error = %e, "Failed to upload summary");
                    }
                }
            }
            Err(e) => {
                error!(provider = %provider.as_str(), error = %e, "Failed to generate summary");
            }
        }
    }

    if new_manifest_entries.is_empty() {
        error!("No summaries were generated successfully");
        return Err("No summaries generated".into());
    }

    // 6. Update Manifest
    info!("Updating manifest.json");
    let manifest_obj_name = "manifest.json";

    // Download existing manifest
    let mut manifest: Vec<ManifestEntry> = match gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: manifest_obj_name.to_string(),
            ..Default::default()
        },
        &Range::default()
    ).await {
        Ok(data) => {
            serde_json::from_slice(&data).map_err(|e| {
                error!(error = %e, "Failed to parse existing manifest.json - file may be corrupted");
                e
            })?
        },
        // Note: GCS SDK doesn't expose structured error types, so we match on message.
        // Both "No such object" and "404" patterns are checked for robustness.
        Err(e) if e.to_string().contains("No such object") || e.to_string().contains("404") => {
            info!("No existing manifest.json found, creating new one");
            Vec::new()
        },
        Err(e) => {
            return Err(format!("Failed to download manifest.json: {}", e).into());
        }
    };

    // Remove existing entries for today (all models)
    manifest.retain(|e| e.date != today);

    // Add new entries at the beginning
    for entry in new_manifest_entries.into_iter().rev() {
        manifest.insert(0, entry);
    }

    // Upload manifest
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    gcs_client.upload_object(
        &UploadObjectRequest {
            bucket: bucket_name.to_string(),
            ..Default::default()
        },
        manifest_json,
        &UploadType::Simple(Media::new(manifest_obj_name.to_string()))
    ).await?;

    info!(date = %today, "Manifest updated successfully");
    info!("SE Daily Agent completed successfully");

    Ok(())
}

#[instrument(skip(client, url), fields(url_domain = %extract_domain(url)))]
async fn fetch_article_content(client: &reqwest::Client, url: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let response = client.get(url).send().await?;
    let html_content = response.text().await?;

    let parsed_url = url::Url::parse(url)
        .map_err(|e| format!("URL parse error: {:?}", e))?;

    let mut reader = Cursor::new(html_content.as_bytes());
    let product = extractor::extract(&mut reader, &parsed_url)
        .map_err(|e| format!("Readability extract error: {:?}", e))?;

    Ok(product.text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_selection_index_simple() {
        assert_eq!(parse_selection_index("5"), Some(5));
        assert_eq!(parse_selection_index("0"), Some(0));
        assert_eq!(parse_selection_index("42"), Some(42));
    }

    #[test]
    fn test_parse_selection_index_with_whitespace() {
        assert_eq!(parse_selection_index("  3  "), Some(3));
        assert_eq!(parse_selection_index("\n7\n"), Some(7));
        assert_eq!(parse_selection_index("\t12"), Some(12));
    }

    #[test]
    fn test_parse_selection_index_with_text() {
        // Gemini sometimes returns text before/after the number
        assert_eq!(parse_selection_index("I choose 5"), Some(5));
        assert_eq!(parse_selection_index("Article 3 is best"), Some(3));
        assert_eq!(parse_selection_index("The answer is: 7."), Some(7));
    }

    #[test]
    fn test_parse_selection_index_invalid() {
        assert_eq!(parse_selection_index("no number here"), None);
        assert_eq!(parse_selection_index(""), None);
        assert_eq!(parse_selection_index("   "), None);
    }

    #[test]
    fn test_parse_selection_index_first_number_only() {
        // Should only get the first contiguous digit sequence
        assert_eq!(parse_selection_index("3 and 5"), Some(3));
        assert_eq!(parse_selection_index("article 2, not 7"), Some(2));
    }

    #[test]
    fn test_parse_selection_index_large_number() {
        assert_eq!(parse_selection_index("99999"), Some(99999));
        assert_eq!(parse_selection_index("1000000"), Some(1000000));
    }

    #[test]
    fn test_parse_selection_index_zero() {
        assert_eq!(parse_selection_index("0"), Some(0));
        assert_eq!(parse_selection_index("The index is 0."), Some(0));
    }

    #[test]
    fn test_parse_selection_index_decimal_takes_integer_part() {
        // "3.5" — should parse "3" as the first contiguous digit sequence
        // since "." breaks the digit run
        let result = parse_selection_index("3.5");
        assert_eq!(result, Some(3));
    }

    #[test]
    fn test_parse_selection_index_negative_ignored() {
        // "-5" — the minus sign is not a digit, so it should find "5"
        let result = parse_selection_index("-5");
        assert_eq!(result, Some(5));
    }

    #[test]
    fn test_parse_selection_index_only_special_chars() {
        assert_eq!(parse_selection_index("!@#$%^&*()"), None);
        assert_eq!(parse_selection_index("..."), None);
    }
}
