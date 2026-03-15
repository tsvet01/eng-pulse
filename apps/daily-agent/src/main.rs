mod fetcher;
mod prompts;

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
const EVAL_DEFAULT_SCORE: u64 = 3;
const EVAL_MAX_TOTAL: f64 = 20.0;

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
    /// Which prompt version generated this summary ("v2" for beta, null for prod)
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_version: Option<String>,
    /// Quality score from LLM judge (0.0-1.0)
    #[serde(skip_serializing_if = "Option::is_none")]
    eval_score: Option<f64>,
}

/// Eval report stored in GCS at eval/{date}.json
/// Currently parsed dynamically via serde_json::Value; typed structs retained for schema documentation.
#[derive(Serialize, Deserialize, Debug, Clone)]
#[allow(dead_code)]
struct EvalReport {
    date: String,
    scores: Vec<EvalEntry>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[allow(dead_code)]
struct EvalEntry {
    /// Composite key: "{prompt_version}-{provider}", e.g. "v1-gemini"
    summary_id: String,
    prompt_version: String,
    model: String,
    title: String,
    scores: EvalCriteria,
    /// Normalized 0.0-1.0 (sum of 4 scores / 20)
    total: f64,
    judge_reasoning: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[allow(dead_code)]
struct EvalCriteria {
    clarity: u8,
    actionability: u8,
    information_density: u8,
    structure: u8,
}

/// Get list of enabled LLM providers based on available API keys.
/// Claude is first for article selection, others follow for summary generation.
fn get_enabled_providers() -> Vec<(LlmProvider, String)> {
    let providers = [LlmProvider::Claude, LlmProvider::Gemini];
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
        error!("No LLM providers configured. Set at least one of: GEMINI_API_KEY, ANTHROPIC_API_KEY");
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

    let prod_config = prompts::PromptConfig::V1;
    let selection_prompt = prod_config.selection_prompt(&articles_text);

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

    let summary_prompt = prod_config.summary_prompt(&best_article.source, &best_article.title, &truncated_text);

    // --- Manifest: download once, all stages append, single upload at the end ---
    let today = Utc::now().format("%Y-%m-%d").to_string();

    let mut manifest: Vec<ManifestEntry> = match gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: "manifest.json".to_string(),
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
    let mut new_manifest_entries: Vec<ManifestEntry> = Vec::new();

    // --- Stage 2: Prod (v1) ---

    for (provider, api_key) in &enabled_providers {
        info!(provider = %provider.as_str(), "Generating summary");

        match call_llm_with_retry(&http_client, *provider, api_key, summary_prompt.clone()).await {
            Ok(summary) => {
                info!(provider = %provider.as_str(), "Summary generated successfully");
                debug!(provider = %provider.as_str(), summary_length = summary.len(), "Summary details");

                // Create snippet BEFORE modifying summary
                let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();

                // Upload Summary to GCS (provider-specific path)
                // Metadata (original_url, model, selected_by) lives in manifest.json
                let object_name = format!("summaries/{}/{}.md", provider.as_str(), today);
                let summary_bytes = summary.into_bytes();

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
                            prompt_version: None,
                            eval_score: None,
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

    // --- Stage 3: Beta (v2) ---
    // Only runs if Claude API key is available
    let claude_entry = enabled_providers.iter().find(|(p, _)| *p == LlmProvider::Claude);
    if let Some((_, claude_key)) = claude_entry {
        info!("Starting beta pipeline (v2)");
        let beta_config = prompts::PromptConfig::V2;

        // Beta selection: pick a different article using persona-driven prompt
        let beta_selection_prompt = beta_config.selection_prompt(&articles_text);
        match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, beta_selection_prompt).await {
            Ok(beta_selected) => {
                let beta_index = parse_selection_index(&beta_selected).unwrap_or(0);
                let beta_safe_index = if beta_index >= all_articles.len() { 0 } else { beta_index };
                let beta_article = &all_articles[beta_safe_index];
                info!(title = %beta_article.title, "Beta selected article");

                // V2 summary of prod article A (guaranteed comparison)
                let beta_summary_prompt_a = beta_config.summary_prompt(
                    &best_article.source, &best_article.title, &truncated_text
                );
                match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, beta_summary_prompt_a).await {
                    Ok(summary) => {
                        let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();
                        let object_name = format!("summaries/beta/claude/{}.md", today);
                        let summary_bytes = summary.into_bytes();

                        match gcs_client.upload_object(
                            &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                            summary_bytes,
                            &UploadType::Simple(Media::new(object_name.clone()))
                        ).await {
                            Ok(_) => {
                                let public_url = format!("https://storage.googleapis.com/{}/{}", bucket_name, object_name);
                                new_manifest_entries.push(ManifestEntry {
                                    date: today.clone(),
                                    url: public_url,
                                    title: best_article.title.clone(),
                                    summary_snippet,
                                    original_url: Some(best_article.url.clone()),
                                    model: Some(LlmProvider::Claude.model_name().to_string()),
                                    selected_by: Some(selection_provider.model_name().to_string()),
                                    prompt_version: Some(beta_config.version().to_string()),
                                    eval_score: None,
                                });
                                info!("Beta summary of prod article uploaded");
                            }
                            Err(e) => warn!(error = %e, "Failed to upload beta summary of prod article"),
                        }
                    }
                    Err(e) => warn!(error = %e, "Failed to generate beta summary of prod article"),
                }

                // V2 summary of beta article B (only if different from A)
                if beta_article.url != best_article.url {
                    info!(title = %beta_article.title, "Beta article differs from prod, generating summary");
                    let beta_article_content = match fetch_article_content(&http_client, &beta_article.url).await {
                        Ok(content) => content,
                        Err(e) => {
                            warn!(error = %e, "Failed to fetch beta article content, using title");
                            format!("Title: {}, URL: {}", beta_article.title, beta_article.url)
                        }
                    };
                    let beta_truncated: String = beta_article_content.chars().take(MAX_ARTICLE_CHARS).collect();
                    let beta_summary_prompt_b = beta_config.summary_prompt(
                        &beta_article.source, &beta_article.title, &beta_truncated
                    );
                    match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, beta_summary_prompt_b).await {
                        Ok(summary) => {
                            let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();
                            let object_name = format!("summaries/beta/claude/{}-selection.md", today);
                            let summary_bytes = summary.into_bytes();

                            match gcs_client.upload_object(
                                &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                                summary_bytes,
                                &UploadType::Simple(Media::new(object_name.clone()))
                            ).await {
                                Ok(_) => {
                                    let public_url = format!("https://storage.googleapis.com/{}/{}", bucket_name, object_name);
                                    new_manifest_entries.push(ManifestEntry {
                                        date: today.clone(),
                                        url: public_url,
                                        title: beta_article.title.clone(),
                                        summary_snippet,
                                        original_url: Some(beta_article.url.clone()),
                                        model: Some(LlmProvider::Claude.model_name().to_string()),
                                        selected_by: Some(format!("{} ({})", LlmProvider::Claude.model_name(), beta_config.version())),
                                        prompt_version: Some(beta_config.version().to_string()),
                                        eval_score: None,
                                    });
                                    info!("Beta summary of beta article uploaded");
                                }
                                Err(e) => warn!(error = %e, "Failed to upload beta selection summary"),
                            }
                        }
                        Err(e) => warn!(error = %e, "Failed to generate beta selection summary"),
                    }
                } else {
                    info!("Beta selected same article as prod, skipping duplicate summary");
                }
            }
            Err(e) => warn!(error = %e, "Beta selection failed, skipping beta pipeline"),
        }
    } else {
        info!("ANTHROPIC_API_KEY not set, skipping beta pipeline");
    }

    // --- Stage 4: Eval ---
    if let Some((_, claude_key)) = claude_entry {
        info!("Starting eval stage");

        // Collect all summaries generated today for evaluation
        let mut eval_summaries: Vec<(String, String)> = Vec::new(); // (summary_id, content)

        for entry in &new_manifest_entries {
            let provider = entry.model.as_deref().unwrap_or("unknown");
            let version = entry.prompt_version.as_deref().unwrap_or("v1");
            let suffix = if entry.url.contains("-selection.md") { "-selection" } else { "" };
            let summary_id = format!("{}-{}{}", version, provider.split('-').next().unwrap_or(provider), suffix);

            // Download the summary we just uploaded
            match gcs_client.download_object(
                &GetObjectRequest {
                    bucket: bucket_name.to_string(),
                    object: entry.url.replace(&format!("https://storage.googleapis.com/{}/", bucket_name), ""),
                    ..Default::default()
                },
                &Range::default()
            ).await {
                Ok(data) => {
                    if let Ok(content) = String::from_utf8(data) {
                        eval_summaries.push((summary_id, content));
                    }
                }
                Err(e) => warn!(summary_id = %summary_id, error = %e, "Failed to download summary for eval"),
            }
        }

        if !eval_summaries.is_empty() {
            let mut eval_prompt = String::from(
                "You are evaluating article summaries for quality. Score each summary on these criteria (1-5):\n\n\
                1. Clarity: How easy is it to scan and understand on a mobile phone?\n\
                2. Actionability: Does it provide concrete takeaways the reader can act on this week?\n\
                3. Information density: What is the signal-to-noise ratio? Is every sentence valuable?\n\
                4. Structure: Is it well-formatted with clear sections, bold key phrases, scannable bullets?\n\n\
                The reader is a senior engineering leader. They have 2-3 minutes on their phone.\n\n\
                For each summary below, return ONLY a JSON object (no markdown fences):\n\
                {\"scores\": [{\"summary_id\": \"id\", \"clarity\": N, \"actionability\": N, \"information_density\": N, \"structure\": N, \"reasoning\": \"...\"}]}\n\n"
            );

            for (id, content) in &eval_summaries {
                eval_prompt.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
            }

            match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, eval_prompt).await {
                Ok(eval_response) => {
                    // Parse JSON from response (handle possible markdown fences)
                    let cleaned = eval_response
                        .trim()
                        .trim_start_matches("```json")
                        .trim_start_matches("```")
                        .trim_end_matches("```")
                        .trim();

                    match serde_json::from_str::<serde_json::Value>(cleaned) {
                        Ok(json) => {
                            if let Some(scores) = json.get("scores").and_then(|s| s.as_array()) {
                                for score in scores {
                                    let summary_id = score.get("summary_id").and_then(|s| s.as_str()).unwrap_or("");
                                    let clarity = score.get("clarity").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as u8;
                                    let actionability = score.get("actionability").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as u8;
                                    let info_density = score.get("information_density").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as u8;
                                    let structure_score = score.get("structure").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as u8;
                                    let total = (clarity as f64 + actionability as f64 + info_density as f64 + structure_score as f64) / EVAL_MAX_TOTAL;
                                    let reasoning = score.get("reasoning").and_then(|s| s.as_str()).unwrap_or("").to_string();

                                    info!(summary_id = %summary_id, total = %total, reasoning = %reasoning, "Eval score");

                                    // Update matching manifest entry
                                    for entry in &mut new_manifest_entries {
                                        let provider = entry.model.as_deref().unwrap_or("unknown");
                                        let version = entry.prompt_version.as_deref().unwrap_or("v1");
                                        let suffix = if entry.url.contains("-selection.md") { "-selection" } else { "" };
                                        let entry_id = format!("{}-{}{}", version, provider.split('-').next().unwrap_or(provider), suffix);
                                        if entry_id == summary_id {
                                            entry.eval_score = Some(total);
                                        }
                                    }
                                }
                            }

                            // Upload eval report
                            let eval_object = format!("eval/{}.json", today);
                            if let Ok(eval_json) = serde_json::to_vec_pretty(&json) {
                                match gcs_client.upload_object(
                                    &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                                    eval_json,
                                    &UploadType::Simple(Media::new(eval_object))
                                ).await {
                                    Ok(_) => info!("Eval report uploaded"),
                                    Err(e) => warn!(error = %e, "Failed to upload eval report"),
                                }
                            }
                        }
                        Err(e) => warn!(error = %e, "Failed to parse eval response as JSON"),
                    }
                }
                Err(e) => warn!(error = %e, "Eval stage failed"),
            }
        }
    } else {
        info!("ANTHROPIC_API_KEY not set, skipping eval stage");
    }

    // --- Final: Upload manifest (all stages have appended to new_manifest_entries) ---
    for entry in new_manifest_entries.into_iter().rev() {
        manifest.insert(0, entry);
    }
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    gcs_client.upload_object(
        &UploadObjectRequest {
            bucket: bucket_name.to_string(),
            ..Default::default()
        },
        manifest_json,
        &UploadType::Simple(Media::new("manifest.json".to_string()))
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
