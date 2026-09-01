mod eval;
mod feedback;
mod fetcher;
mod manifest;
mod prompts;

/// Parse an index from LLM response, extracting the first contiguous digit sequence.
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

/// Parse comma-separated indices from LLM shortlist response (e.g., "3,7,12,25,41").
fn parse_shortlist_indices(response: &str, max_index: usize) -> Vec<usize> {
    response
        .trim()
        .split(',')
        .filter_map(|s| parse_selection_index(s.trim()))
        .filter(|&i| i < max_index)
        .collect()
}

/// Operational mode selected from CLI arguments.
#[derive(Debug, PartialEq, Clone, Copy)]
enum RunMode {
    /// Normal nightly run: summarize the last 24h, write to today's date.
    Normal,
    /// Deploy gate: one real LLM call per provider, no side effects.
    Smoke,
    /// Backfill a single past day from articles actually published then.
    Backfill(chrono::NaiveDate),
}

/// Parse the operational mode from CLI args.
///
/// `--smoke` takes precedence (a deploy smoke check must never trigger a real
/// backfill). `--date YYYY-MM-DD` selects backfill for that single UTC day.
fn parse_run_mode(args: &[String]) -> Result<RunMode, String> {
    if args.iter().any(|a| a == "--smoke") {
        return Ok(RunMode::Smoke);
    }
    if let Some(pos) = args.iter().position(|a| a == "--date") {
        let value = args
            .get(pos + 1)
            .ok_or("--date requires a YYYY-MM-DD argument")?;
        let date = chrono::NaiveDate::parse_from_str(value, "%Y-%m-%d")
            .map_err(|e| format!("invalid --date '{}': {}", value, e))?;
        return Ok(RunMode::Backfill(date));
    }
    Ok(RunMode::Normal)
}

/// Content snippet length for two-phase selection
const SELECTION_SNIPPET_CHARS: usize = 1000;

/// Manifest-less summary id for the shadow V3 lane; never written to manifest.json.
const SHADOW_SUMMARY_ID: &str = "v3-shadow";

/// Empty or unset SHADOW_MODEL disables the shadow lane.
fn shadow_model_from(env_val: Option<String>) -> Option<String> {
    env_val.filter(|m| !m.is_empty())
}

/// Head-to-head judge instruction; scores alone saturate at the ceiling.
fn pairwise_instruction(has_shadow: bool) -> &'static str {
    if has_shadow {
        "The summaries cover the same article. After scoring, compare them head-to-head and add one top-level field to the same JSON object:\n\
         \"pairwise_winner\": the summary_id of the summary a senior engineering leader should prefer, or \"tie\" only if they are genuinely indistinguishable. Scores may be equal while one summary is still clearly preferable — decide the winner independently of the scores.\n\n"
    } else {
        ""
    }
}

fn shadow_model() -> Option<String> {
    shadow_model_from(std::env::var("SHADOW_MODEL").ok())
}
use crate::fetcher::{Article, SourceConfig};
use chrono::Utc;
use gcloud_storage::client::{Client, ClientConfig};
use gcloud_storage::http::objects::download::Range;
use gcloud_storage::http::objects::get::GetObjectRequest;
use gcloud_storage::http::objects::upload::{Media, UploadObjectRequest, UploadType};
use llm_client::{
    call_llm, call_llm_with_retry, extract_domain, get_api_key_env_var, init_logging, LlmOptions,
    LlmProvider, DEFAULT_BUCKET,
};
use readability::extractor;
use std::io::Cursor;
use std::time::Duration;
use tracing::{debug, error, info, instrument, warn};

use crate::eval::{apply_eval_scores, log_calibration_agreement, run_eval_pass};
use crate::feedback::{build_calibration_context, build_selection_context, load_recent_feedback};
use crate::manifest::{gcs_object_path, gcs_public_url, ManifestEntry, SUMMARY_SNIPPET_CHARS};
use futures::future::join_all;

// --- Configuration Constants ---
const HTTP_TIMEOUT_SECS: u64 = 60;
const MAX_ARTICLE_CHARS: usize = 50_000;
/// Minimum extracted content length to attempt summarization.
/// Pages below this threshold are likely JS-rendered SPAs or paywalled.
const MIN_ARTICLE_CHARS: usize = 200;

fn build_recent_picks_context(manifest: &[ManifestEntry], max_days: usize) -> Option<String> {
    let recent: Vec<&ManifestEntry> = manifest
        .iter()
        .filter(|e| e.prompt_version.is_none()) // Only production picks
        .take(max_days)
        .collect();

    if recent.is_empty() {
        return None;
    }

    let mut context = String::from("Recent selections (avoid repetition):\n");
    for entry in &recent {
        context.push_str(&format!("- {}: \"{}\"\n", entry.date, entry.title));
    }
    context.push_str("Prefer a different topic domain today.\n");
    Some(context)
}

/// Get list of enabled LLM providers based on available API keys.
/// Claude is first for article selection, others follow for summary generation.
/// Minimal end-to-end check used as a post-deploy gate: make one real LLM call
/// per enabled provider and fail if any provider rejects the request. Catches
/// API/model contract breakage (a deprecated parameter, a bad model id, an auth
/// problem) at deploy time instead of on the next nightly run. No GCS or
/// notification side effects.
async fn run_smoke(
    http_client: &reqwest::Client,
    providers: &[(LlmProvider, String)],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut failures = Vec::new();
    for (provider, key) in providers {
        let prompt = "Reply with the single word: OK".to_string();
        match call_llm(http_client, *provider, key, prompt, &LlmOptions::default()).await {
            Ok(resp) => {
                info!(provider = %provider.as_str(), reply = %resp.trim(), "Smoke check passed")
            }
            Err(e) => {
                error!(provider = %provider.as_str(), error = %e, "Smoke check FAILED");
                failures.push(format!("{}: {}", provider.as_str(), e));
            }
        }
    }

    // Also smoke-check the shadow model, if configured, so a bad SHADOW_MODEL
    // id fails the deploy gate instead of surfacing as a nightly warn.
    if let Some(shadow) = shadow_model() {
        if let Some((_, claude_key)) = providers.iter().find(|(p, _)| *p == LlmProvider::Claude) {
            let prompt = "Reply with the single word: OK".to_string();
            let options = LlmOptions {
                model: Some(shadow.clone()),
                ..Default::default()
            };
            match call_llm(
                http_client,
                LlmProvider::Claude,
                claude_key,
                prompt,
                &options,
            )
            .await
            {
                Ok(resp) => {
                    info!(provider = "claude", model = %shadow, reply = %resp.trim(), "Shadow smoke check passed")
                }
                Err(e) => {
                    error!(provider = "claude", model = %shadow, error = %e, "Shadow smoke check FAILED");
                    failures.push(format!("shadow({}): {}", shadow, e));
                }
            }
        }
    }

    if failures.is_empty() {
        info!("Smoke test passed for all providers");
        Ok(())
    } else {
        Err(format!("Smoke test failed: {}", failures.join("; ")).into())
    }
}

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
        .map(|d| {
            (now - chrono::Duration::days(d as i64))
                .format("%Y-%m-%d")
                .to_string()
        })
        .collect();

    info!(dates = ?target_dates, "Backfilling beta summaries");

    // Download manifest
    let mut manifest: Vec<ManifestEntry> = {
        let data = gcs_client
            .download_object(
                &GetObjectRequest {
                    bucket: bucket_name.to_string(),
                    object: "manifest.json".to_string(),
                    ..Default::default()
                },
                &Range::default(),
            )
            .await?;
        serde_json::from_slice(&data)?
    };

    let beta_config = prompts::PromptConfig::V2;

    for date in &target_dates {
        // Find a prod entry for this date (prompt_version is None for v1)
        let prod_entry = manifest
            .iter()
            .find(|e| e.date == *date && e.prompt_version.is_none() && e.original_url.is_some());

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

                match gcs_client
                    .upload_object(
                        &UploadObjectRequest {
                            bucket: bucket_name.to_string(),
                            ..Default::default()
                        },
                        summary_bytes,
                        &UploadType::Simple(Media::new(object_name.clone())),
                    )
                    .await
                {
                    Ok(_) => {
                        let public_url = gcs_public_url(bucket_name, &object_name);

                        // Remove old beta entries for this date
                        manifest.retain(|e| {
                            !(e.date == *date && e.prompt_version.as_deref() == Some("v2"))
                        });

                        // Find insertion point: after the last entry for this date
                        let insert_idx = manifest
                            .iter()
                            .position(|e| e.date < *date)
                            .unwrap_or(manifest.len());
                        manifest.insert(
                            insert_idx,
                            ManifestEntry {
                                date: date.clone(),
                                url: public_url,
                                title: title.clone(),
                                summary_snippet,
                                original_url: Some(original_url.clone()),
                                model: Some(LlmProvider::Claude.model_name().to_string()),
                                selected_by: None,
                                prompt_version: Some(beta_config.version().to_string()),
                                eval_score: None,
                                format: None,
                            },
                        );

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
    gcs_client
        .upload_object(
            &UploadObjectRequest {
                bucket: bucket_name.to_string(),
                ..Default::default()
            },
            manifest_json,
            &UploadType::Simple(Media::new("manifest.json".to_string())),
        )
        .await?;

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
        error!(
            "No LLM providers configured. Set at least one of: GEMINI_API_KEY, ANTHROPIC_API_KEY"
        );
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

    // Resolve operational mode from CLI args. Smoke mode exits before any GCS
    // work so it can run as a lightweight post-deploy gate.
    let run_mode = parse_run_mode(&std::env::args().collect::<Vec<_>>()).map_err(|e| {
        error!(error = %e, "Invalid arguments");
        e
    })?;
    if run_mode == RunMode::Smoke {
        info!("Running in smoke-test mode (no GCS/notification side effects)");
        return run_smoke(&http_client, &enabled_providers).await;
    }

    // Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);

    // --- Backfill mode: regenerate V2 beta summaries for recent days ---
    if let Ok(days_str) = std::env::var("BACKFILL_BETA_DAYS") {
        let days: usize = days_str.parse().unwrap_or(3);
        let claude_key = enabled_providers
            .iter()
            .find(|(p, _)| *p == LlmProvider::Claude)
            .map(|(_, k)| k.as_str())
            .ok_or("BACKFILL_BETA_DAYS requires ANTHROPIC_API_KEY")?;
        return backfill_beta(days, &http_client, &gcs_client, &bucket_name, claude_key).await;
    }

    // Resolve the run date and the publish-date window for fetching. Backfill
    // restricts to a single past UTC day so only articles actually published
    // then are summarized; the normal run keeps the last 24h.
    let is_backfill = matches!(run_mode, RunMode::Backfill(_));
    let (today, fetch_window) = match run_mode {
        RunMode::Backfill(date) => {
            info!(date = %date, "Backfill mode: regenerating brief from articles published that day");
            (
                date.format("%Y-%m-%d").to_string(),
                fetcher::FetchWindow::day(date),
            )
        }
        _ => (
            Utc::now().format("%Y-%m-%d").to_string(),
            fetcher::FetchWindow::last_24h(),
        ),
    };

    // Use first provider for article selection (Claude preferred)
    let (selection_provider, selection_key) = enabled_providers.first().unwrap().clone();

    // 1. Load Sources from GCS
    info!("Fetching sources.json from GCS");
    let sources_data = gcs_client
        .download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object: "config/sources.json".to_string(),
                ..Default::default()
            },
            &Range::default(),
        )
        .await?;

    let sources: Vec<SourceConfig> = serde_json::from_slice(&sources_data)?;
    info!(count = sources.len(), "Loaded sources from Cloud Storage");

    // 2. Fetch Articles (use a dedicated client for fetching with appropriate timeout)
    let fetch_client = fetcher::create_http_client()?;
    info!("Fetching headlines from sources");
    let mut all_articles: Vec<Article> = Vec::new();
    for source in sources {
        debug!(source = %source.name, "Fetching from source");
        match fetcher::fetch_from_source(&source, &fetch_client, fetch_window).await {
            Ok(mut articles) => {
                info!(source = %source.name, count = articles.len(), "Found articles");
                all_articles.append(&mut articles);
            }
            Err(e) => warn!(source = %source.name, error = %e, "Failed to fetch from source"),
        }
    }

    if all_articles.is_empty() {
        warn!("No recent articles found from any source");
        return Ok(());
    }

    info!(
        total_articles = all_articles.len(),
        "Total articles collected"
    );

    // --- Manifest: download once, all stages append, single upload at the end ---
    let mut manifest: Vec<ManifestEntry> = match gcs_client
        .download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object: "manifest.json".to_string(),
                ..Default::default()
            },
            &Range::default(),
        )
        .await
    {
        Ok(data) => serde_json::from_slice(&data).map_err(|e| {
            error!(error = %e, "Failed to parse existing manifest.json - file may be corrupted");
            e
        })?,
        Err(e) if e.to_string().contains("No such object") || e.to_string().contains("404") => {
            info!("No existing manifest.json found, creating new one");
            Vec::new()
        }
        Err(e) => {
            return Err(format!("Failed to download manifest.json: {}", e).into());
        }
    };

    // Cross-day dedup: collect URLs selected in the last 7 days. Skipped when
    // backfilling — a past day should be rebuilt on its own merits, not filtered
    // against picks from days that chronologically came after it.
    let recent_urls: std::collections::HashSet<String> = if is_backfill {
        std::collections::HashSet::new()
    } else {
        manifest
            .iter()
            .filter(|e| {
                e.date
                    >= Utc::now()
                        .checked_sub_signed(chrono::Duration::days(7))
                        .map(|d| d.format("%Y-%m-%d").to_string())
                        .unwrap_or_default()
            })
            .filter(|e| e.prompt_version.is_none()) // only dedup against v1 (prod) picks
            .filter_map(|e| e.original_url.clone())
            .collect()
    };

    let pre_dedup_count = all_articles.len();
    all_articles.retain(|a| !recent_urls.contains(&a.url));
    if all_articles.len() < pre_dedup_count {
        info!(
            removed = pre_dedup_count - all_articles.len(),
            remaining = all_articles.len(),
            "Filtered articles already selected in last 7 days"
        );
    }

    if all_articles.is_empty() {
        warn!("No articles remain after dedup — all recent articles were already selected");
        return Ok(());
    }

    // Remove existing entries for today (all models)
    manifest.retain(|e| e.date != today);
    let mut new_manifest_entries: Vec<ManifestEntry> = Vec::new();

    // --- Load user feedback early (needed for selection context) ---
    let recent_feedback = load_recent_feedback(&gcs_client, &bucket_name).await;
    let selection_context = build_selection_context(&recent_feedback, &manifest);
    let recent_picks = build_recent_picks_context(&manifest, 5);

    // 3. Two-phase selection: shortlist by headlines, then pick by content
    info!(provider = %selection_provider.as_str(), "Phase 1: Shortlisting top candidates from headlines");

    let mut articles_text = String::new();
    for (i, article) in all_articles.iter().enumerate() {
        articles_text.push_str(&format!("{}. [{}] {}\n", i, article.source, article.title));
    }

    let prod_config = prompts::PromptConfig::V1;
    let selection_opts = LlmOptions {
        temperature: Some(0.3),
        ..Default::default()
    };

    // Phase 1: Shortlist top 5 from headlines
    let shortlist_prompt = prod_config.shortlist_prompt_with_context(
        &articles_text,
        selection_context.as_deref(),
        recent_picks.as_deref(),
    );
    let shortlist_response = call_llm(
        &http_client,
        selection_provider,
        &selection_key,
        shortlist_prompt,
        &selection_opts,
    )
    .await?;
    let mut shortlist = parse_shortlist_indices(&shortlist_response, all_articles.len());

    // Fallback: if shortlist parsing fails, use single-shot selection
    if shortlist.is_empty() {
        warn!(response = %shortlist_response.trim(), "Failed to parse shortlist, falling back to single-shot");
        let fallback_prompt = prod_config.selection_prompt(&articles_text);
        let fallback = call_llm(
            &http_client,
            selection_provider,
            &selection_key,
            fallback_prompt,
            &selection_opts,
        )
        .await?;
        let idx = parse_selection_index(&fallback)
            .unwrap_or(0)
            .min(all_articles.len().saturating_sub(1));
        shortlist = vec![idx];
    }

    info!(candidates = ?shortlist, "Shortlisted candidates");

    // Phase 2: Fetch content snippets for shortlisted articles, then final pick
    let safe_index = if shortlist.len() == 1 {
        shortlist[0]
    } else {
        info!(
            "Phase 2: Fetching content for {} candidates",
            shortlist.len()
        );
        let mut candidates_text = String::new();
        for &idx in &shortlist {
            let article = &all_articles[idx];
            let snippet = match fetch_article_content(&http_client, &article.url).await {
                Ok(content) => {
                    let s: String = content.chars().take(SELECTION_SNIPPET_CHARS).collect();
                    s
                }
                Err(e) => {
                    debug!(title = %article.title, error = %e, "Could not fetch content for candidate");
                    "(content unavailable)".to_string()
                }
            };
            candidates_text.push_str(&format!(
                "--- Article {} ---\n[{}] {}\n\n{}\n\n",
                idx, article.source, article.title, snippet
            ));
        }

        let final_prompt = prod_config.final_selection_prompt_with_context(
            &candidates_text,
            selection_context.as_deref(),
            recent_picks.as_deref(),
        );
        let final_response = call_llm(
            &http_client,
            selection_provider,
            &selection_key,
            final_prompt,
            &selection_opts,
        )
        .await?;
        let picked = parse_selection_index(&final_response).unwrap_or(shortlist[0]);

        // Validate the pick is in our shortlist
        if shortlist.contains(&picked) {
            picked
        } else {
            warn!(
                picked = picked,
                "Final pick not in shortlist, using first candidate"
            );
            shortlist[0]
        }
    };

    let best_article = &all_articles[safe_index];
    info!(
        title = %best_article.title,
        url = %best_article.url,
        source = %best_article.source,
        "Selected best article"
    );

    // 4. Fetch full article content (may reuse cached content from phase 2)
    info!("Fetching full article content");

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

    let summary_prompt =
        prod_config.summary_prompt(&best_article.source, &best_article.title, &truncated_text);

    // --- Stage 2: Prod (v1) — parallel LLM calls ---

    info!(
        "Generating summaries in parallel across {} provider(s)",
        enabled_providers.len()
    );

    let summary_futures: Vec<_> = enabled_providers
        .iter()
        .map(|(provider, api_key)| {
            let client = http_client.clone();
            let key = api_key.clone();
            let prompt = summary_prompt.clone();
            let p = *provider;
            async move {
                let result = call_llm_with_retry(&client, p, &key, prompt).await;
                (p, result)
            }
        })
        .collect();

    let llm_results = join_all(summary_futures).await;

    // GCS uploads happen sequentially after all LLM calls complete
    for (provider, result) in llm_results {
        match result {
            Ok(summary) => {
                info!(provider = %provider.as_str(), "Summary generated successfully");
                debug!(provider = %provider.as_str(), summary_length = summary.len(), "Summary details");

                // Create snippet BEFORE converting summary to bytes
                let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();

                // Upload Summary to GCS (provider-specific path)
                // Metadata (original_url, model, selected_by) lives in manifest.json
                let object_name = format!("summaries/{}/{}.md", provider.as_str(), today);
                let summary_bytes = summary.into_bytes();

                info!(provider = %provider.as_str(), object = %object_name, "Uploading summary to GCS");

                let upload_type = UploadType::Simple(Media::new(object_name.clone()));
                match gcs_client
                    .upload_object(
                        &UploadObjectRequest {
                            bucket: bucket_name.to_string(),
                            ..Default::default()
                        },
                        summary_bytes,
                        &upload_type,
                    )
                    .await
                {
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
                            format: None,
                        });
                    }
                    Err(e) => {
                        error!(provider = %provider.as_str(), error = %e, "Failed to upload summary");
                    }
                }
            }
            Err(e) => {
                warn!(provider = %provider.as_str(), error = %e, "Summary generation failed");
            }
        }
    }

    if new_manifest_entries.is_empty() {
        error!("No summaries were generated successfully");
        return Err("No summaries generated".into());
    }

    // --- Stage 3: V3 Insight Brief ---
    info!("=== Stage 3: V3 Insight Brief ===");
    let v3_config = prompts::PromptConfig::V3;
    let mut shadow_v3_json: Option<String> = None;

    let claude_entry = enabled_providers
        .iter()
        .find(|(p, _)| *p == LlmProvider::Claude);
    if let Some((_, claude_key)) = claude_entry {
        let v3_prompt =
            v3_config.summary_prompt(&best_article.source, &best_article.title, &truncated_text);
        let v3_options = LlmOptions {
            temperature: Some(0.3),
            ..Default::default()
        };

        match call_llm(
            &http_client,
            LlmProvider::Claude,
            claude_key,
            v3_prompt,
            &v3_options,
        )
        .await
        {
            Ok(response) => {
                let json_str = response.trim();
                // Strip markdown code fences if present
                // Extract JSON: find first { and last } to handle preamble or code fences
                let clean_json =
                    if let (Some(start), Some(end)) = (json_str.find('{'), json_str.rfind('}')) {
                        json_str[start..=end].to_string()
                    } else {
                        json_str.to_string()
                    };

                match serde_json::from_str::<serde_json::Value>(&clean_json) {
                    Ok(parsed)
                        if parsed.get("key_idea").is_some()
                            && parsed.get("deep_dive").is_some() =>
                    {
                        let object_path = format!("summaries/v3/{}.json", today);
                        let public_url = gcs_public_url(&bucket_name, &object_path);

                        match gcs_client
                            .upload_object(
                                &UploadObjectRequest {
                                    bucket: bucket_name.clone(),
                                    ..Default::default()
                                },
                                clean_json.as_bytes().to_vec(),
                                &UploadType::Simple(Media::new(object_path.clone())),
                            )
                            .await
                        {
                            Ok(_) => {
                                let snippet = parsed["key_idea"].as_str().unwrap_or("").to_string();
                                let snippet_truncated =
                                    if snippet.chars().count() > SUMMARY_SNIPPET_CHARS {
                                        format!(
                                            "{}...",
                                            snippet
                                                .chars()
                                                .take(SUMMARY_SNIPPET_CHARS - 3)
                                                .collect::<String>()
                                        )
                                    } else {
                                        snippet
                                    };

                                new_manifest_entries.push(ManifestEntry {
                                    date: today.clone(),
                                    url: public_url,
                                    title: best_article.title.clone(),
                                    summary_snippet: snippet_truncated,
                                    original_url: Some(best_article.url.clone()),
                                    model: Some(LlmProvider::Claude.model_name().to_string()),
                                    selected_by: Some(selection_provider.model_name().to_string()),
                                    prompt_version: Some("v3".to_string()),
                                    eval_score: None,
                                    format: Some("insight-brief-v3".to_string()),
                                });
                                info!("V3 Insight Brief uploaded to {}", object_path);
                            }
                            Err(e) => warn!(error = %e, "Failed to upload V3 Insight Brief"),
                        }
                    }
                    Ok(_) => warn!("V3 response missing required fields, skipping"),
                    Err(e) => warn!(error = %e, "V3 response is not valid JSON, skipping"),
                }
            }
            Err(e) => warn!(error = %e, "V3 summary generation failed"),
        }

        // Shadow lane: same prompt, candidate model; never enters the manifest.
        if let Some(shadow) = shadow_model() {
            let shadow_prompt = v3_config.summary_prompt(
                &best_article.source,
                &best_article.title,
                &truncated_text,
            );
            // Opus 5 adaptive thinking tokens count against max_tokens; raise
            // the cap so the JSON answer isn't truncated. Prod paths keep the
            // 4096 default.
            let shadow_options = LlmOptions {
                model: Some(shadow.clone()),
                max_tokens: Some(16000),
                ..Default::default()
            };

            match call_llm(
                &http_client,
                LlmProvider::Claude,
                claude_key,
                shadow_prompt,
                &shadow_options,
            )
            .await
            {
                Ok(response) => {
                    let json_str = response.trim();
                    let clean_json = if let (Some(start), Some(end)) =
                        (json_str.find('{'), json_str.rfind('}'))
                    {
                        json_str[start..=end].to_string()
                    } else {
                        json_str.to_string()
                    };

                    match serde_json::from_str::<serde_json::Value>(&clean_json) {
                        Ok(parsed)
                            if parsed.get("key_idea").is_some()
                                && parsed.get("deep_dive").is_some() =>
                        {
                            let object_path = format!("summaries/v3-shadow/{}.json", today);
                            match gcs_client
                                .upload_object(
                                    &UploadObjectRequest {
                                        bucket: bucket_name.clone(),
                                        ..Default::default()
                                    },
                                    clean_json.as_bytes().to_vec(),
                                    &UploadType::Simple(Media::new(object_path.clone())),
                                )
                                .await
                            {
                                Ok(_) => {
                                    info!(model = %shadow, "Shadow V3 brief uploaded to {}", object_path);
                                    shadow_v3_json = Some(clean_json);
                                }
                                Err(e) => warn!(error = %e, "Failed to upload shadow V3 brief"),
                            }
                        }
                        _ => warn!(model = %shadow, "Shadow V3 response invalid, skipping"),
                    }
                }
                Err(e) => warn!(model = %shadow, error = %e, "Shadow V3 generation failed"),
            }
        }
    } else {
        info!("Skipping V3: no Claude API key available");
    }

    // --- Build calibration context from already-loaded feedback ---
    let calibration_context =
        build_calibration_context(&recent_feedback, &gcs_client, &bucket_name, &manifest).await;

    // --- Stage 4: Eval (dual pass with calibration) ---
    // Use Gemini as judge to avoid self-preference bias (Claude judging Claude summaries)
    let eval_entry = enabled_providers
        .iter()
        .find(|(p, _)| *p == LlmProvider::Gemini)
        .or(enabled_providers
            .iter()
            .find(|(p, _)| *p == LlmProvider::Claude));
    if let Some((eval_provider, eval_key)) = eval_entry {
        info!(provider = %eval_provider.as_str(), "Starting eval stage");

        // Collect all summaries generated today for evaluation
        let mut eval_summaries: Vec<(String, String)> = Vec::new(); // (summary_id, content)

        for entry in &new_manifest_entries {
            let summary_id = entry.summary_id();

            // Download the summary we just uploaded
            match gcs_client
                .download_object(
                    &GetObjectRequest {
                        bucket: bucket_name.to_string(),
                        object: gcs_object_path(&entry.url, &bucket_name).to_string(),
                        ..Default::default()
                    },
                    &Range::default(),
                )
                .await
            {
                Ok(data) => {
                    if let Ok(content) = String::from_utf8(data) {
                        eval_summaries.push((summary_id, content));
                    }
                }
                Err(e) => {
                    warn!(summary_id = %summary_id, error = %e, "Failed to download summary for eval")
                }
            }
        }

        // Split summaries into V1 (markdown) and V3 (insight-brief) for separate eval rubrics
        let (v1_summaries, v3_summaries): (Vec<_>, Vec<_>) =
            eval_summaries.iter().partition(|(id, _)| {
                !new_manifest_entries.iter().any(|e| {
                    e.summary_id() == *id && e.format.as_deref() == Some("insight-brief-v3")
                })
            });

        // Eval V1 summaries with standard rubric
        if !v1_summaries.is_empty() {
            let v1_prompt = String::from(
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
            let mut section = String::new();
            for (id, content) in &v1_summaries {
                section.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
            }
            if let Some(json) = run_eval_pass(
                &http_client,
                *eval_provider,
                eval_key,
                format!("{}{}", v1_prompt, section),
                &gcs_client,
                &bucket_name,
                &today,
                "eval",
            )
            .await
            {
                apply_eval_scores(&json, &mut new_manifest_entries);
            }
        }

        // Eval V3 summaries with insight-brief rubric
        if !v3_summaries.is_empty() || shadow_v3_json.is_some() {
            let v3_prompt = String::from(
                "You are evaluating Insight Brief summaries for a senior engineering leader (C++/Rust, hedge fund, low-latency systems).\n\n\
                Score each summary on these criteria (1-5 scale):\n\
                1. key_idea_clarity: Is the key insight distilled into one clear, non-hedging sentence?\n\
                2. why_it_matters_relevance: Does it connect to the reader's specific context?\n\
                3. deep_dive_depth: Is the technical analysis substantive, with evidence and nuance?\n\
                4. action_quality: If present, is the action concrete and genuinely useful? (Score 3 if no action item.)\n\n\
                For each summary below, return ONLY a JSON object (no markdown fences):\n\
                {\"scores\": [{\"summary_id\": \"id\", \"key_idea_clarity\": N, \"why_it_matters_relevance\": N, \"deep_dive_depth\": N, \"action_quality\": N, \"reasoning\": \"...\"}]}\n\n"
            );
            let mut section = String::new();
            for (id, content) in &v3_summaries {
                section.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
            }
            if let Some(json) = &shadow_v3_json {
                section.push_str(&format!(
                    "--- Summary: {} ---\n{}\n\n",
                    SHADOW_SUMMARY_ID, json
                ));
            }
            if let Some(json) = run_eval_pass(
                &http_client,
                *eval_provider,
                eval_key,
                format!(
                    "{}{}{}",
                    v3_prompt,
                    pairwise_instruction(shadow_v3_json.is_some()),
                    section
                ),
                &gcs_client,
                &bucket_name,
                &today,
                "eval-v3",
            )
            .await
            {
                apply_eval_scores(&json, &mut new_manifest_entries);
            }
        }

        // Calibrated eval pass (V1 only — calibration feedback is based on V1 format)
        if !v1_summaries.is_empty() {
            if let Some(ref cal_context) = calibration_context {
                info!("Running calibrated eval pass");
                let v1_prompt = String::from(
                    "You are evaluating article summaries for quality. Score each summary on these criteria (1-5):\n\n\
                    1. Clarity\n2. Actionability\n3. Information density\n4. Faithfulness\n\n\
                    The reader is a senior engineering leader. They have 2-3 minutes on their phone.\n\
                    Return ONLY JSON: {\"scores\": [{\"summary_id\": \"id\", \"clarity\": N, \"actionability\": N, \"information_density\": N, \"faithfulness\": N, \"reasoning\": \"...\"}]}\n\n"
                );
                let mut section = String::new();
                for (id, content) in &v1_summaries {
                    section.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
                }
                let calibrated_prompt = format!("{}{}\n{}", v1_prompt, cal_context, section);
                if let Some(cal_json) = run_eval_pass(
                    &http_client,
                    *eval_provider,
                    eval_key,
                    calibrated_prompt,
                    &gcs_client,
                    &bucket_name,
                    &today,
                    "eval-calibrated",
                )
                .await
                {
                    apply_eval_scores(&cal_json, &mut new_manifest_entries);
                    log_calibration_agreement(&recent_feedback, &cal_json, &new_manifest_entries);
                }
            }
        }
    } else {
        info!("No LLM provider available for eval, skipping eval stage");
    }

    // --- Final: Upload manifest (all stages have appended to new_manifest_entries) ---
    for entry in new_manifest_entries.into_iter().rev() {
        manifest.insert(0, entry);
    }
    // Keep the manifest newest-first by date regardless of insertion order. This
    // matters for backfill (--date), where a past day's entries would otherwise
    // be prepended ahead of newer ones. Stable sort preserves intra-date order.
    manifest.sort_by(|a, b| b.date.cmp(&a.date));
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    gcs_client
        .upload_object(
            &UploadObjectRequest {
                bucket: bucket_name.to_string(),
                ..Default::default()
            },
            manifest_json,
            &UploadType::Simple(Media::new("manifest.json".to_string())),
        )
        .await?;

    info!(date = %today, "Manifest updated successfully");
    info!("SE Daily Agent completed successfully");

    Ok(())
}

#[instrument(skip(client, url), fields(url_domain = %extract_domain(url)))]
async fn fetch_article_content(
    client: &reqwest::Client,
    url: &str,
) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let response = client.get(url).send().await?;
    let html_content = response.text().await?;

    let parsed_url = url::Url::parse(url).map_err(|e| format!("URL parse error: {:?}", e))?;

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
    use serial_test::serial;

    fn args(items: &[&str]) -> Vec<String> {
        std::iter::once("daily-agent")
            .chain(items.iter().copied())
            .map(String::from)
            .collect()
    }

    #[test]
    fn test_parse_run_mode_normal() {
        assert_eq!(parse_run_mode(&args(&[])), Ok(RunMode::Normal));
    }

    #[test]
    fn test_parse_run_mode_smoke() {
        assert_eq!(parse_run_mode(&args(&["--smoke"])), Ok(RunMode::Smoke));
    }

    #[test]
    fn test_parse_run_mode_smoke_takes_precedence_over_date() {
        // A deploy smoke check must never accidentally run a real backfill.
        assert_eq!(
            parse_run_mode(&args(&["--date", "2026-05-26", "--smoke"])),
            Ok(RunMode::Smoke)
        );
    }

    #[test]
    fn test_parse_run_mode_backfill() {
        let d = chrono::NaiveDate::from_ymd_opt(2026, 5, 26).unwrap();
        assert_eq!(
            parse_run_mode(&args(&["--date", "2026-05-26"])),
            Ok(RunMode::Backfill(d))
        );
    }

    #[test]
    fn test_parse_run_mode_date_missing_value() {
        assert!(parse_run_mode(&args(&["--date"])).is_err());
    }

    #[test]
    fn test_parse_run_mode_date_invalid() {
        assert!(parse_run_mode(&args(&["--date", "not-a-date"])).is_err());
        assert!(parse_run_mode(&args(&["--date", "2026-13-45"])).is_err());
    }

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

    #[test]
    fn test_pairwise_instruction_present_with_shadow() {
        let ins = pairwise_instruction(true);
        assert!(ins.contains("pairwise_winner"));
        assert!(ins.contains("tie"));
    }

    #[test]
    fn test_pairwise_instruction_empty_without_shadow() {
        assert_eq!(pairwise_instruction(false), "");
    }

    #[test]
    fn test_shadow_model_reads_env() {
        // Pure precedence check via the helper's inner fn.
        assert_eq!(
            shadow_model_from(Some("claude-opus-5".to_string())),
            Some("claude-opus-5".to_string())
        );
        assert_eq!(shadow_model_from(Some(String::new())), None); // empty = off
        assert_eq!(shadow_model_from(None), None);
    }

    // --- run_smoke: shadow model gating (finding 5) ---
    //
    // A bad SHADOW_MODEL id must fail the deploy smoke gate instead of only
    // surfacing as a nightly warn once the real run tries the shadow lane.
    // #[serial] because these tests mutate process env vars (CLAUDE_BASE_URL,
    // SHADOW_MODEL) shared with other tests in this binary.

    #[tokio::test]
    #[serial]
    async fn test_run_smoke_fails_when_shadow_model_smoke_call_fails() {
        use wiremock::matchers::{body_partial_json, method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;

        // Prod smoke call (default model, no override) succeeds.
        Mock::given(method("POST"))
            .and(path("/messages"))
            .and(body_partial_json(
                serde_json::json!({"model": "claude-opus-4-8"}),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "content": [{"text": "OK"}]
            })))
            .with_priority(1)
            .mount(&mock_server)
            .await;

        // Shadow smoke call, using a bad model id the way a SHADOW_MODEL typo
        // would, fails.
        Mock::given(method("POST"))
            .and(path("/messages"))
            .and(body_partial_json(
                serde_json::json!({"model": "claude-bad-shadow"}),
            ))
            .respond_with(ResponseTemplate::new(400).set_body_json(serde_json::json!({
                "error": {"message": "model: claude-bad-shadow not found"}
            })))
            .with_priority(1)
            .mount(&mock_server)
            .await;

        unsafe {
            std::env::set_var("CLAUDE_BASE_URL", mock_server.uri());
            std::env::set_var("SHADOW_MODEL", "claude-bad-shadow");
        }

        let providers = vec![(LlmProvider::Claude, "test-key".to_string())];
        let result = run_smoke(&reqwest::Client::new(), &providers).await;

        unsafe {
            std::env::remove_var("CLAUDE_BASE_URL");
            std::env::remove_var("SHADOW_MODEL");
        }

        let err = result.expect_err("a failing shadow smoke call must fail the whole gate");
        assert!(
            err.to_string().contains("claude-bad-shadow"),
            "error should name the shadow model, got: {err}"
        );
    }

    #[tokio::test]
    #[serial]
    async fn test_run_smoke_passes_when_shadow_model_smoke_call_succeeds() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;

        Mock::given(method("POST"))
            .and(path("/messages"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "content": [{"text": "OK"}]
            })))
            .mount(&mock_server)
            .await;

        unsafe {
            std::env::set_var("CLAUDE_BASE_URL", mock_server.uri());
            std::env::set_var("SHADOW_MODEL", "claude-opus-5");
        }

        let providers = vec![(LlmProvider::Claude, "test-key".to_string())];
        let result = run_smoke(&reqwest::Client::new(), &providers).await;

        unsafe {
            std::env::remove_var("CLAUDE_BASE_URL");
            std::env::remove_var("SHADOW_MODEL");
        }

        assert!(
            result.is_ok(),
            "smoke should pass when both prod and shadow calls succeed: {result:?}"
        );
    }
}
