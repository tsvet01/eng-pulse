mod fetcher;
mod prompts;
mod eval;
mod feedback;
mod manifest;

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

use crate::manifest::{ManifestEntry, gcs_public_url, gcs_object_path, SUMMARY_SNIPPET_CHARS};
use crate::eval::{run_eval_pass, apply_eval_scores, log_calibration_agreement};
use crate::feedback::{load_recent_feedback, build_calibration_context};

// --- Configuration Constants ---
const HTTP_TIMEOUT_SECS: u64 = 60;
const MAX_ARTICLE_CHARS: usize = 50_000;
/// Minimum extracted content length to attempt summarization.
/// Pages below this threshold are likely JS-rendered SPAs or paywalled.
const MIN_ARTICLE_CHARS: usize = 200;

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

// --- Backfill Beta ---

/// Re-generate V2 beta summaries for recent days using existing manifest entries.
/// Reads the manifest, finds prod entries for the target dates, fetches original articles,
/// generates new V2 summaries, and updates the manifest.
async fn backfill_beta(
    days: usize,
    http_client: &reqwest::Client,
    gcs_client: &Client,
    bucket_name: &str,
    claude_key: &str,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let now = Utc::now();
    let target_dates: Vec<String> = (1..=days)
        .map(|d| (now - chrono::Duration::days(d as i64)).format("%Y-%m-%d").to_string())
        .collect();

    info!(dates = ?target_dates, "Backfilling beta summaries");

    // Download manifest
    let mut manifest: Vec<ManifestEntry> = {
        let data = gcs_client.download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object: "manifest.json".to_string(),
                ..Default::default()
            },
            &Range::default(),
        ).await?;
        serde_json::from_slice(&data)?
    };

    let beta_config = prompts::PromptConfig::V2;

    for date in &target_dates {
        // Find a prod entry for this date (prompt_version is None for v1)
        let prod_entry = manifest.iter().find(|e| {
            e.date == *date && e.prompt_version.is_none() && e.original_url.is_some()
        });

        let (title, original_url) = match prod_entry {
            Some(e) => (e.title.clone(), e.original_url.clone().unwrap()),
            None => {
                warn!(date = %date, "No prod entry found, skipping");
                continue;
            }
        };

        info!(date = %date, title = %title, "Backfilling beta summary");

        // Fetch original article content
        let article_text = match fetch_article_content(http_client, &original_url).await {
            Ok(content) => content,
            Err(e) => {
                warn!(date = %date, error = %e, "Failed to fetch article, skipping");
                continue;
            }
        };
        let truncated: String = article_text.chars().take(MAX_ARTICLE_CHARS).collect();
        let source = extract_domain(&original_url);

        let prompt = beta_config.summary_prompt(&source, &title, &truncated);
        match call_llm_with_retry(http_client, LlmProvider::Claude, claude_key, prompt).await {
            Ok(summary) => {
                let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();
                let object_name = format!("summaries/beta/claude/{}.md", date);
                let summary_bytes = summary.into_bytes();

                match gcs_client.upload_object(
                    &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                    summary_bytes,
                    &UploadType::Simple(Media::new(object_name.clone())),
                ).await {
                    Ok(_) => {
                        let public_url = gcs_public_url(bucket_name, &object_name);

                        // Remove old beta entries for this date
                        manifest.retain(|e| !(e.date == *date && e.prompt_version.as_deref() == Some("v2")));

                        // Find insertion point: after the last entry for this date
                        let insert_idx = manifest.iter().position(|e| e.date < *date).unwrap_or(manifest.len());
                        manifest.insert(insert_idx, ManifestEntry {
                            date: date.clone(),
                            url: public_url,
                            title: title.clone(),
                            summary_snippet,
                            original_url: Some(original_url.clone()),
                            model: Some(LlmProvider::Claude.model_name().to_string()),
                            selected_by: None,
                            prompt_version: Some(beta_config.version().to_string()),
                            eval_score: None,
                        });

                        info!(date = %date, "Beta summary backfilled");
                    }
                    Err(e) => warn!(date = %date, error = %e, "Failed to upload backfill summary"),
                }
            }
            Err(e) => warn!(date = %date, error = %e, "Failed to generate backfill summary"),
        }
    }

    // Upload updated manifest
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    gcs_client.upload_object(
        &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
        manifest_json,
        &UploadType::Simple(Media::new("manifest.json".to_string())),
    ).await?;

    info!(days = days, "Beta backfill complete");
    Ok(())
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

    // 0. Initialize shared HTTP client (reused for connection pooling)
    let http_client = reqwest::Client::builder()
        .timeout(Duration::from_secs(HTTP_TIMEOUT_SECS))
        .build()?;

    // Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);

    // --- Backfill mode: regenerate V2 beta summaries for recent days ---
    if let Ok(days_str) = std::env::var("BACKFILL_BETA_DAYS") {
        let days: usize = days_str.parse().unwrap_or(3);
        let claude_key = enabled_providers.iter()
            .find(|(p, _)| *p == LlmProvider::Claude)
            .map(|(_, k)| k.as_str())
            .ok_or("BACKFILL_BETA_DAYS requires ANTHROPIC_API_KEY")?;
        return backfill_beta(days, &http_client, &gcs_client, &bucket_name, claude_key).await;
    }

    // Use first provider for article selection (Claude preferred)
    let (selection_provider, selection_key) = enabled_providers.first().unwrap().clone();

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

                        let public_url = gcs_public_url(&bucket_name, &object_name);
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
                                let public_url = gcs_public_url(&bucket_name, &object_name);
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
                            warn!(error = %e, "Skipping beta selection summary");
                            String::new()
                        }
                    };
                    if beta_article_content.is_empty() {
                        // Content extraction failed — skip rather than generating noise
                    } else {
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
                                    let public_url = gcs_public_url(&bucket_name, &object_name);
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

    // --- Load user feedback for calibration ---
    let feedback = load_recent_feedback(&gcs_client, &bucket_name).await;
    let calibration_context = build_calibration_context(&feedback, &gcs_client, &bucket_name, &manifest).await;

    // --- Stage 4: Eval (dual pass with calibration) ---
    if let Some((_, claude_key)) = claude_entry {
        info!("Starting eval stage");

        // Collect all summaries generated today for evaluation
        let mut eval_summaries: Vec<(String, String)> = Vec::new(); // (summary_id, content)

        for entry in &new_manifest_entries {
            let summary_id = entry.summary_id();

            // Download the summary we just uploaded
            match gcs_client.download_object(
                &GetObjectRequest {
                    bucket: bucket_name.to_string(),
                    object: gcs_object_path(&entry.url, &bucket_name).to_string(),
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
            let base_eval_prompt = String::from(
                "You are evaluating article summaries for quality. Score each summary on these criteria (1-5):\n\n\
                1. Clarity: How easy is it to scan and understand on a mobile phone?\n\
                2. Actionability: Does it provide concrete takeaways the reader can act on this week?\n\
                3. Information density: What is the signal-to-noise ratio? Is every sentence valuable?\n\
                4. Faithfulness: Does the summary accurately represent the source without adding unsupported claims or forced conclusions?\n\n\
                The reader is a senior engineering leader. They have 2-3 minutes on their phone.\n\
                Judge the content quality, not whether it uses any particular formatting style.\n\n\
                For each summary below, return ONLY a JSON object (no markdown fences):\n\
                {\"scores\": [{\"summary_id\": \"id\", \"clarity\": N, \"actionability\": N, \"information_density\": N, \"faithfulness\": N, \"reasoning\": \"...\"}]}\n\n"
            );

            let mut summaries_section = String::new();
            for (id, content) in &eval_summaries {
                summaries_section.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
            }

            // Pass 1: Uncalibrated eval
            let uncalibrated_prompt = format!("{}{}", base_eval_prompt, summaries_section);
            if let Some(json) = run_eval_pass(
                &http_client, claude_key, uncalibrated_prompt, &gcs_client, &bucket_name, &today, "eval"
            ).await {
                apply_eval_scores(&json, &mut new_manifest_entries);
            }

            // Pass 2: Calibrated eval (only if calibration context is available)
            if let Some(ref cal_context) = calibration_context {
                info!("Running calibrated eval pass");
                let calibrated_prompt = format!("{}{}\n{}", base_eval_prompt, cal_context, summaries_section);
                if let Some(cal_json) = run_eval_pass(
                    &http_client, claude_key, calibrated_prompt, &gcs_client, &bucket_name, &today, "eval-calibrated"
                ).await {
                    // Calibrated scores override uncalibrated
                    apply_eval_scores(&cal_json, &mut new_manifest_entries);
                    log_calibration_agreement(&feedback, &cal_json, &new_manifest_entries);
                }
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

    let text = product.text;
    if text.chars().count() < MIN_ARTICLE_CHARS {
        return Err(format!(
            "Extracted content too short ({} chars, minimum {}). Page is likely JS-rendered or paywalled.",
            text.chars().count(), MIN_ARTICLE_CHARS
        ).into());
    }

    Ok(text)
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
