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
    call_llm, extract_domain, get_api_key_env_var, init_logging, LlmOptions, LlmProvider,
    DEFAULT_BUCKET,
};
use readability::extractor;
use std::io::Cursor;
use std::time::Duration;
use tracing::{debug, error, info, instrument, warn};

use crate::eval::{apply_eval_scores, run_eval_pass};
use crate::feedback::{build_selection_context, load_recent_feedback};
use crate::manifest::{gcs_public_url, ManifestEntry, SUMMARY_SNIPPET_CHARS};

// --- Configuration Constants ---
const HTTP_TIMEOUT_SECS: u64 = 60;
const MAX_ARTICLE_CHARS: usize = 50_000;
/// Minimum extracted content length to attempt summarization.
/// Pages below this threshold are likely JS-rendered SPAs or paywalled.
const MIN_ARTICLE_CHARS: usize = 200;

/// The entry that represents a day's pick: the V3 brief, or the V1 summary
/// on days before V3 existed. Excludes beta lanes.
fn is_daily_pick(entry: &ManifestEntry) -> bool {
    matches!(entry.prompt_version.as_deref(), None | Some("v3"))
}

/// One line per recent day so the selector avoids repeating topics. Takes the
/// first entry seen for each of the first `max_days` distinct dates.
fn build_recent_picks_context(manifest: &[ManifestEntry], max_days: usize) -> Option<String> {
    let mut seen_dates = std::collections::HashSet::new();
    let mut recent: Vec<&ManifestEntry> = Vec::new();
    for entry in manifest.iter().filter(|e| is_daily_pick(e)) {
        if recent.len() >= max_days {
            break;
        }
        if seen_dates.insert(entry.date.as_str()) {
            recent.push(entry);
        }
    }

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

/// API keys the pipeline needs: Claude writes the brief, OpenAI judges it.
/// Gemini is optional and unused by the daily run; when present it is only
/// exercised by `--smoke`.
#[derive(Debug, Clone, PartialEq)]
struct ApiKeys {
    claude: String,
    openai: String,
    gemini: Option<String>,
}

/// Claude and OpenAI keys are required; an empty value counts as missing.
fn api_keys_from(
    claude: Option<String>,
    openai: Option<String>,
    gemini: Option<String>,
) -> Result<ApiKeys, String> {
    let claude = claude.filter(|k| !k.is_empty());
    let openai = openai.filter(|k| !k.is_empty());
    let gemini = gemini.filter(|k| !k.is_empty());
    match (claude, openai) {
        (Some(claude), Some(openai)) => Ok(ApiKeys {
            claude,
            openai,
            gemini,
        }),
        (claude, openai) => {
            let missing: Vec<&str> = [
                (claude.is_none(), LlmProvider::Claude),
                (openai.is_none(), LlmProvider::OpenAI),
            ]
            .into_iter()
            .filter(|(missing, _)| *missing)
            .map(|(_, provider)| get_api_key_env_var(provider))
            .collect();
            Err(format!(
                "Missing required API key(s): {}",
                missing.join(", ")
            ))
        }
    }
}

fn load_api_keys() -> Result<ApiKeys, String> {
    api_keys_from(
        std::env::var(get_api_key_env_var(LlmProvider::Claude)).ok(),
        std::env::var(get_api_key_env_var(LlmProvider::OpenAI)).ok(),
        std::env::var(get_api_key_env_var(LlmProvider::Gemini)).ok(),
    )
}

/// Minimal end-to-end check used as a post-deploy gate: one real LLM call per
/// provider, failing if any rejects the request. Catches API/model contract
/// breakage (a deprecated parameter, a bad model id, an auth problem) at
/// deploy time instead of on the next nightly run. No GCS or notification
/// side effects.
async fn run_smoke(
    http_client: &reqwest::Client,
    keys: &ApiKeys,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // The shadow model, if configured, is checked too so a bad SHADOW_MODEL id
    // fails the deploy gate instead of surfacing as a nightly warn.
    let shadow = shadow_model();
    let checks = [
        (LlmProvider::Claude, keys.claude.as_str(), None),
        (LlmProvider::OpenAI, keys.openai.as_str(), None),
    ]
    .into_iter()
    .chain(
        shadow
            .as_deref()
            .map(|m| (LlmProvider::Claude, keys.claude.as_str(), Some(m))),
    )
    .chain(
        keys.gemini
            .as_deref()
            .map(|k| (LlmProvider::Gemini, k, None)),
    );

    let mut failures = Vec::new();
    for (provider, key, model) in checks {
        let label = match model {
            Some(m) => format!("shadow({})", m),
            None => provider.as_str().to_string(),
        };
        let options = LlmOptions {
            model: model.map(String::from),
            ..Default::default()
        };
        let prompt = "Reply with the single word: OK".to_string();
        match call_llm(http_client, provider, key, prompt, &options).await {
            Ok(resp) => info!(check = %label, reply = %resp.trim(), "Smoke check passed"),
            Err(e) => {
                error!(check = %label, error = %e, "Smoke check FAILED");
                failures.push(format!("{}: {}", label, e));
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

/// A validated Insight Brief: the JSON object as uploaded plus its key idea.
struct InsightBrief {
    json: String,
    key_idea: String,
}

/// Extract the JSON object from an LLM response (tolerating preamble or code
/// fences) and require the brief's mandatory fields.
fn parse_insight_brief(response: &str) -> Option<InsightBrief> {
    let start = response.find('{')?;
    let end = response.rfind('}')?;
    let json = response.get(start..=end)?;
    let parsed: serde_json::Value = serde_json::from_str(json).ok()?;
    parsed.get("deep_dive")?;
    let key_idea = parsed.get("key_idea")?.as_str().unwrap_or("").to_string();
    Some(InsightBrief {
        json: json.to_string(),
        key_idea,
    })
}

/// Truncate text to the manifest snippet length, marking the cut.
fn manifest_snippet(text: &str) -> String {
    if text.chars().count() > SUMMARY_SNIPPET_CHARS {
        format!(
            "{}...",
            text.chars()
                .take(SUMMARY_SNIPPET_CHARS - 3)
                .collect::<String>()
        )
    } else {
        text.to_string()
    }
}

// --- Main ---

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    dotenvy::dotenv().ok();
    init_logging();

    let bucket_name = std::env::var("GCS_BUCKET").unwrap_or_else(|_| DEFAULT_BUCKET.to_string());

    let keys = load_api_keys().map_err(|e| {
        error!(error = %e, "LLM credentials not configured");
        e
    })?;

    info!(bucket = %bucket_name, "Starting SE Daily Agent");

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
        return run_smoke(&http_client, &keys).await;
    }

    // Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);

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
            .filter(|e| is_daily_pick(e))
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

    // Remove existing entries for today
    manifest.retain(|e| e.date != today);

    // --- Load user feedback early (needed for selection context) ---
    let recent_feedback = load_recent_feedback(&gcs_client, &bucket_name).await;
    let selection_context = build_selection_context(&recent_feedback, &manifest);
    let recent_picks = build_recent_picks_context(&manifest, 5);

    // 3. Two-phase selection: shortlist by headlines, then pick by content
    info!(
        provider = "claude",
        "Phase 1: Shortlisting top candidates from headlines"
    );

    let mut articles_text = String::new();
    for (i, article) in all_articles.iter().enumerate() {
        articles_text.push_str(&format!("{}. [{}] {}\n", i, article.source, article.title));
    }

    let selection_opts = LlmOptions::default();

    // Phase 1: Shortlist top 5 from headlines
    let shortlist_prompt = prompts::shortlist_prompt_with_context(
        &articles_text,
        selection_context.as_deref(),
        recent_picks.as_deref(),
    );
    let shortlist_response = call_llm(
        &http_client,
        LlmProvider::Claude,
        &keys.claude,
        shortlist_prompt,
        &selection_opts,
    )
    .await?;
    let mut shortlist = parse_shortlist_indices(&shortlist_response, all_articles.len());

    // Fallback: if shortlist parsing fails, use single-shot selection
    if shortlist.is_empty() {
        warn!(response = %shortlist_response.trim(), "Failed to parse shortlist, falling back to single-shot");
        let fallback_prompt = prompts::selection_prompt(&articles_text);
        let fallback = call_llm(
            &http_client,
            LlmProvider::Claude,
            &keys.claude,
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

        let final_prompt = prompts::final_selection_prompt_with_context(
            &candidates_text,
            selection_context.as_deref(),
            recent_picks.as_deref(),
        );
        let final_response = call_llm(
            &http_client,
            LlmProvider::Claude,
            &keys.claude,
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

    // --- V3 Insight Brief ---
    // The brief is the run's only product: a failure here (after call_llm's
    // transient-error retries) fails the run.
    info!("Generating V3 Insight Brief");
    let v3_prompt =
        prompts::summary_prompt(&best_article.source, &best_article.title, &truncated_text);
    let v3_options = LlmOptions::default();
    let response = call_llm(
        &http_client,
        LlmProvider::Claude,
        &keys.claude,
        v3_prompt,
        &v3_options,
    )
    .await
    .map_err(|e| format!("V3 Insight Brief generation failed: {}", e))?;
    let brief = parse_insight_brief(&response)
        .ok_or("V3 response is not a valid Insight Brief (invalid JSON or missing fields)")?;

    let object_path = format!("summaries/v3/{}.json", today);
    gcs_client
        .upload_object(
            &UploadObjectRequest {
                bucket: bucket_name.clone(),
                ..Default::default()
            },
            brief.json.as_bytes().to_vec(),
            &UploadType::Simple(Media::new(object_path.clone())),
        )
        .await
        .map_err(|e| format!("Failed to upload V3 Insight Brief: {}", e))?;
    info!("V3 Insight Brief uploaded to {}", object_path);

    let mut entry = ManifestEntry {
        date: today.clone(),
        url: gcs_public_url(&bucket_name, &object_path),
        title: best_article.title.clone(),
        summary_snippet: manifest_snippet(&brief.key_idea),
        original_url: Some(best_article.url.clone()),
        model: Some(LlmProvider::Claude.model_name().to_string()),
        selected_by: Some(LlmProvider::Claude.model_name().to_string()),
        prompt_version: Some(prompts::PROMPT_VERSION.to_string()),
        eval_score: None,
        format: Some("insight-brief-v3".to_string()),
    };

    // Shadow lane: same prompt, candidate model; never enters the manifest.
    let mut shadow_v3_json: Option<String> = None;
    if let Some(shadow) = shadow_model() {
        let shadow_prompt =
            prompts::summary_prompt(&best_article.source, &best_article.title, &truncated_text);
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
            &keys.claude,
            shadow_prompt,
            &shadow_options,
        )
        .await
        {
            Ok(response) => match parse_insight_brief(&response) {
                Some(shadow_brief) => {
                    let object_path = format!("summaries/v3-shadow/{}.json", today);
                    match gcs_client
                        .upload_object(
                            &UploadObjectRequest {
                                bucket: bucket_name.clone(),
                                ..Default::default()
                            },
                            shadow_brief.json.as_bytes().to_vec(),
                            &UploadType::Simple(Media::new(object_path.clone())),
                        )
                        .await
                    {
                        Ok(_) => {
                            info!(model = %shadow, "Shadow V3 brief uploaded to {}", object_path);
                            shadow_v3_json = Some(shadow_brief.json);
                        }
                        Err(e) => warn!(error = %e, "Failed to upload shadow V3 brief"),
                    }
                }
                None => warn!(model = %shadow, "Shadow V3 response invalid, skipping"),
            },
            Err(e) => warn!(model = %shadow, error = %e, "Shadow V3 generation failed"),
        }
    }

    // --- Eval ---
    // A non-Claude judge avoids self-preference bias (Claude judging Claude).
    info!(provider = "openai", "Starting eval stage");
    let v3_eval_prompt = String::from(
        "You are evaluating Insight Brief summaries for a senior engineering leader (C++/Rust, hedge fund, low-latency systems).\n\n\
        Score each summary on these criteria (1-5 scale):\n\
        1. key_idea_clarity: Is the key insight distilled into one clear, non-hedging sentence?\n\
        2. why_it_matters_relevance: Does it connect to the reader's specific context?\n\
        3. deep_dive_depth: Is the technical analysis substantive, with evidence and nuance?\n\
        4. action_quality: If present, is the action concrete and genuinely useful? (Score 3 if no action item.)\n\n\
        For each summary below, return ONLY a JSON object (no markdown fences):\n\
        {\"scores\": [{\"summary_id\": \"id\", \"key_idea_clarity\": N, \"why_it_matters_relevance\": N, \"deep_dive_depth\": N, \"action_quality\": N, \"reasoning\": \"...\"}]}\n\n"
    );
    let mut section = format!(
        "--- Summary: {} ---\n{}\n\n",
        entry.summary_id(),
        brief.json
    );
    if let Some(json) = &shadow_v3_json {
        section.push_str(&format!(
            "--- Summary: {} ---\n{}\n\n",
            SHADOW_SUMMARY_ID, json
        ));
    }
    if let Some(json) = run_eval_pass(
        &http_client,
        LlmProvider::OpenAI,
        &keys.openai,
        format!(
            "{}{}{}",
            v3_eval_prompt,
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
        apply_eval_scores(&json, std::slice::from_mut(&mut entry));
    }

    // --- Final: Upload manifest ---
    manifest.insert(0, entry);
    // Keep the manifest newest-first by date regardless of insertion order. This
    // matters for backfill (--date), where a past day's entry would otherwise
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
        // The judge sometimes returns text before/after the number
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

    // --- Startup credentials ---

    #[test]
    fn test_api_keys_from_both_present() {
        let keys = api_keys_from(Some("c".to_string()), Some("g".to_string()), None).unwrap();
        assert_eq!(
            keys,
            ApiKeys {
                claude: "c".to_string(),
                openai: "g".to_string(),
                gemini: None,
            }
        );
    }

    #[test]
    fn test_api_keys_from_gemini_is_optional() {
        let keys = api_keys_from(
            Some("c".to_string()),
            Some("o".to_string()),
            Some("g".to_string()),
        )
        .unwrap();
        assert_eq!(keys.gemini.as_deref(), Some("g"));
        let keys = api_keys_from(
            Some("c".to_string()),
            Some("o".to_string()),
            Some(String::new()),
        )
        .unwrap();
        assert_eq!(keys.gemini, None);
    }

    #[test]
    fn test_api_keys_from_missing_openai_fails() {
        let err = api_keys_from(Some("c".to_string()), None, None).unwrap_err();
        assert!(err.contains("OPENAI_API_KEY"), "{err}");
        assert!(!err.contains("ANTHROPIC_API_KEY"), "{err}");
    }

    #[test]
    fn test_api_keys_from_empty_claude_counts_as_missing() {
        let err = api_keys_from(Some(String::new()), Some("g".to_string()), None).unwrap_err();
        assert!(err.contains("ANTHROPIC_API_KEY"), "{err}");
    }

    #[test]
    fn test_api_keys_from_both_missing_names_both() {
        let err = api_keys_from(None, None, None).unwrap_err();
        assert!(err.contains("ANTHROPIC_API_KEY"), "{err}");
        assert!(err.contains("OPENAI_API_KEY"), "{err}");
    }

    // --- Insight Brief parsing ---

    #[test]
    fn test_parse_insight_brief_strips_fences_and_preamble() {
        let response =
            "Here you go:\n```json\n{\"key_idea\": \"Idea\", \"deep_dive\": \"Body\"}\n```";
        let brief = parse_insight_brief(response).unwrap();
        assert_eq!(
            brief.json,
            "{\"key_idea\": \"Idea\", \"deep_dive\": \"Body\"}"
        );
        assert_eq!(brief.key_idea, "Idea");
    }

    #[test]
    fn test_parse_insight_brief_requires_fields() {
        assert!(parse_insight_brief("{\"key_idea\": \"Idea\"}").is_none());
        assert!(parse_insight_brief("{\"deep_dive\": \"Body\"}").is_none());
    }

    #[test]
    fn test_parse_insight_brief_rejects_invalid_json() {
        assert!(parse_insight_brief("not json").is_none());
        assert!(parse_insight_brief("{\"key_idea\": ").is_none());
        assert!(parse_insight_brief("} then {").is_none());
    }

    #[test]
    fn test_manifest_snippet_truncates_long_text() {
        let long = "x".repeat(SUMMARY_SNIPPET_CHARS + 20);
        let snippet = manifest_snippet(&long);
        assert_eq!(snippet.chars().count(), SUMMARY_SNIPPET_CHARS);
        assert!(snippet.ends_with("..."));
        assert_eq!(manifest_snippet("short"), "short");
    }

    // --- Recent picks context ---

    fn pick(date: &str, title: &str, prompt_version: Option<&str>) -> ManifestEntry {
        ManifestEntry {
            date: date.to_string(),
            url: format!("https://example.com/{}", title),
            title: title.to_string(),
            summary_snippet: String::new(),
            original_url: None,
            model: None,
            selected_by: None,
            prompt_version: prompt_version.map(String::from),
            eval_score: None,
            format: None,
        }
    }

    #[test]
    fn test_is_daily_pick_accepts_v1_and_v3_only() {
        assert!(is_daily_pick(&pick("2026-09-15", "a", None)));
        assert!(is_daily_pick(&pick("2026-09-15", "a", Some("v3"))));
        assert!(!is_daily_pick(&pick("2026-09-15", "a", Some("v2"))));
    }

    #[test]
    fn test_recent_picks_one_line_per_day_across_v1_and_v3() {
        // Newest-first, with a legacy day carrying two V1 entries plus a V3
        // entry for the same pick, and a V2 beta entry that must be ignored.
        let manifest = vec![
            pick("2026-09-15", "Today", Some("v3")),
            pick("2026-09-14", "Yesterday", Some("v3")),
            pick("2026-09-13", "Legacy", None),
            pick("2026-09-13", "Legacy", None),
            pick("2026-09-13", "Legacy", Some("v3")),
            pick("2026-09-13", "Beta", Some("v2")),
            pick("2026-09-12", "Older", Some("v3")),
        ];
        let ctx = build_recent_picks_context(&manifest, 3).unwrap();
        assert_eq!(ctx.matches("\n- ").count(), 3, "{ctx}");
        assert!(ctx.contains("2026-09-15: \"Today\""));
        assert!(ctx.contains("2026-09-14: \"Yesterday\""));
        assert!(ctx.contains("2026-09-13: \"Legacy\""));
        assert!(!ctx.contains("Beta"));
        assert!(!ctx.contains("Older"));
    }

    #[test]
    fn test_recent_picks_empty_manifest() {
        assert!(build_recent_picks_context(&[], 5).is_none());
    }

    // --- run_smoke: both providers plus the optional shadow model ---
    //
    // A bad SHADOW_MODEL id must fail the deploy smoke gate instead of only
    // surfacing as a nightly warn once the real run tries the shadow lane.
    // #[serial] because these tests mutate process env vars shared with other
    // tests in this binary.

    fn test_keys() -> ApiKeys {
        ApiKeys {
            claude: "test-claude-key".to_string(),
            openai: "test-openai-key".to_string(),
            gemini: None,
        }
    }

    async fn mount_openai_ok(server: &wiremock::MockServer) {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, ResponseTemplate};
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "choices": [{"message": {"content": "OK"}}]
            })))
            .mount(server)
            .await;
    }

    #[tokio::test]
    #[serial]
    async fn test_run_smoke_fails_when_shadow_model_smoke_call_fails() {
        use wiremock::matchers::{body_partial_json, method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;
        mount_openai_ok(&mock_server).await;

        // Prod smoke call (default model, no override) succeeds.
        Mock::given(method("POST"))
            .and(path("/messages"))
            .and(body_partial_json(
                serde_json::json!({"model": llm_client::DEFAULT_CLAUDE_MODEL}),
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
            std::env::set_var("OPENAI_BASE_URL", mock_server.uri());
            std::env::set_var("SHADOW_MODEL", "claude-bad-shadow");
        }

        let result = run_smoke(&reqwest::Client::new(), &test_keys()).await;

        unsafe {
            std::env::remove_var("CLAUDE_BASE_URL");
            std::env::remove_var("OPENAI_BASE_URL");
            std::env::remove_var("SHADOW_MODEL");
        }

        let err = result.expect_err("a failing shadow smoke call must fail the whole gate");
        assert!(
            err.to_string().contains("claude-bad-shadow"),
            "error should name the shadow model, got: {err}"
        );
        assert!(
            !err.to_string().contains("openai:"),
            "openai check should have passed, got: {err}"
        );
    }

    #[tokio::test]
    #[serial]
    async fn test_run_smoke_fails_when_openai_rejects() {
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
        Mock::given(method("POST"))
            .and(path("/chat/completions"))
            .respond_with(ResponseTemplate::new(401).set_body_json(serde_json::json!({
                "error": {"message": "Incorrect API key provided"}
            })))
            .mount(&mock_server)
            .await;

        unsafe {
            std::env::set_var("CLAUDE_BASE_URL", mock_server.uri());
            std::env::set_var("OPENAI_BASE_URL", mock_server.uri());
            std::env::remove_var("SHADOW_MODEL");
        }

        let result = run_smoke(&reqwest::Client::new(), &test_keys()).await;

        unsafe {
            std::env::remove_var("CLAUDE_BASE_URL");
            std::env::remove_var("OPENAI_BASE_URL");
        }

        let err = result.expect_err("a failing OpenAI smoke call must fail the gate");
        assert!(err.to_string().contains("openai:"), "{err}");
    }

    #[tokio::test]
    #[serial]
    async fn test_run_smoke_checks_gemini_only_when_key_is_set() {
        use wiremock::matchers::{method, path, path_regex};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;
        mount_openai_ok(&mock_server).await;
        Mock::given(method("POST"))
            .and(path("/messages"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "content": [{"text": "OK"}]
            })))
            .mount(&mock_server)
            .await;
        Mock::given(method("POST"))
            .and(path_regex(r"^/v1beta/models/.*:generateContent$"))
            .respond_with(ResponseTemplate::new(403).set_body_json(serde_json::json!({
                "error": {"message": "API key not valid"}
            })))
            .mount(&mock_server)
            .await;

        unsafe {
            std::env::set_var("CLAUDE_BASE_URL", mock_server.uri());
            std::env::set_var("OPENAI_BASE_URL", mock_server.uri());
            std::env::set_var("GEMINI_BASE_URL", mock_server.uri());
            std::env::remove_var("SHADOW_MODEL");
        }

        // No Gemini key: the failing Gemini mock is never called.
        let without = run_smoke(&reqwest::Client::new(), &test_keys()).await;
        // With a key: the gemini check runs and its failure fails the gate.
        let with = run_smoke(
            &reqwest::Client::new(),
            &ApiKeys {
                gemini: Some("test-gemini-key".to_string()),
                ..test_keys()
            },
        )
        .await;

        unsafe {
            std::env::remove_var("CLAUDE_BASE_URL");
            std::env::remove_var("OPENAI_BASE_URL");
            std::env::remove_var("GEMINI_BASE_URL");
        }

        assert!(without.is_ok(), "{without:?}");
        let err = with.expect_err("a failing Gemini smoke call must fail the gate");
        assert!(err.to_string().contains("gemini:"), "{err}");
    }

    #[tokio::test]
    #[serial]
    async fn test_run_smoke_passes_when_shadow_model_smoke_call_succeeds() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;
        mount_openai_ok(&mock_server).await;

        Mock::given(method("POST"))
            .and(path("/messages"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "content": [{"text": "OK"}]
            })))
            .mount(&mock_server)
            .await;

        unsafe {
            std::env::set_var("CLAUDE_BASE_URL", mock_server.uri());
            std::env::set_var("OPENAI_BASE_URL", mock_server.uri());
            std::env::set_var("SHADOW_MODEL", "claude-opus-5");
        }

        let result = run_smoke(&reqwest::Client::new(), &test_keys()).await;

        unsafe {
            std::env::remove_var("CLAUDE_BASE_URL");
            std::env::remove_var("OPENAI_BASE_URL");
            std::env::remove_var("SHADOW_MODEL");
        }

        assert!(
            result.is_ok(),
            "smoke should pass when both prod and shadow calls succeed: {result:?}"
        );
    }
}
