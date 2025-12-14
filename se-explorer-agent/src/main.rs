use serde::Deserialize;
use google_cloud_storage::client::{Client, ClientConfig};
use google_cloud_storage::http::objects::download::Range;
use google_cloud_storage::http::objects::get::GetObjectRequest;
use google_cloud_storage::http::objects::upload::{UploadObjectRequest, UploadType, Media};
use select::document::Document;
use select::predicate::{Name, Attr, Predicate};
use std::collections::HashSet;
use url::Url;
use chrono::{DateTime, Utc, Duration};
use rss::Channel;
use atom_syndication::Feed;
use tracing::{info, warn, error, debug, instrument};
use std::time::Duration as StdDuration;
use gemini_engine::{call_gemini_with_retry, init_logging, SourceConfig};

// --- Configuration Constants ---
const HTTP_TIMEOUT_SECS: u64 = 30;
const DEFAULT_BUCKET: &str = "tsvet01-agent-brain";
const FRESHNESS_DAYS: i64 = 90;
const MAX_FEED_DISCOVERY_ATTEMPTS: usize = 2;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    dotenv::dotenv().ok();
    init_logging();

    let gemini_api_key = std::env::var("GEMINI_API_KEY").map_err(|_| {
        error!("GEMINI_API_KEY environment variable not set");
        "GEMINI_API_KEY environment variable not set"
    })?;
    let bucket_name = std::env::var("GCS_BUCKET").unwrap_or_else(|_| DEFAULT_BUCKET.to_string());

    info!(bucket = %bucket_name, "Starting SE Explorer Agent");

    // 1. Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);
    let http_client = reqwest::Client::builder()
        .timeout(StdDuration::from_secs(HTTP_TIMEOUT_SECS))
        .build()?;

    // 2. Load Current Sources
    info!("Downloading current sources from GCS");
    let sources_data = gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: "config/sources.json".to_string(),
            ..Default::default()
        },
        &Range::default()
    ).await?;
    let current_sources: Vec<SourceConfig> = serde_json::from_slice(&sources_data)?;
    let initial_source_count = current_sources.len();
    info!(count = initial_source_count, "Loaded current sources");

    let mut all_sources: HashSet<SourceConfig> = current_sources.iter().cloned().collect();

    // 3. Process User Candidates (if any)
    let user_candidates_object_name = "config/user_candidates.json";
    match gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: user_candidates_object_name.to_string(),
            ..Default::default()
        },
        &Range::default()
    ).await {
        Ok(candidates_data) => {
            info!("Found user_candidates.json, processing new sources");
            let user_recs: Vec<SourceConfig> = serde_json::from_slice(&candidates_data)?;

            for rec in user_recs {
                if !all_sources.contains(&rec) {
                    info!(name = %rec.name, url = %rec.url, "Investigating user candidate");
                    match discover_and_validate_feed(&http_client, &gemini_api_key, &rec.url, &rec.name).await {
                        Ok(Some(validated_source)) => {
                            if !all_sources.contains(&validated_source) {
                                info!(
                                    name = %validated_source.name,
                                    url = %validated_source.url,
                                    "Valid and relevant source found"
                                );
                                all_sources.insert(validated_source);
                            } else {
                                debug!(name = %rec.name, "Validated source already exists, skipping");
                            }
                        },
                        Ok(None) => debug!(name = %rec.name, "Invalid or irrelevant, skipping"),
                        Err(e) => warn!(name = %rec.name, error = %e, "Error processing candidate"),
                    }
                } else {
                    debug!(name = %rec.name, "User candidate already exists, skipping");
                }
            }
            // Delete user_candidates.json after processing
            info!("Deleting user_candidates.json from GCS");
            gcs_client.delete_object(
                &google_cloud_storage::http::objects::delete::DeleteObjectRequest {
                    bucket: bucket_name.to_string(),
                    object: user_candidates_object_name.to_string(),
                    ..Default::default()
                }
            ).await?;
        },
        Err(e) if e.to_string().contains("No such object") => {
            debug!("No user_candidates.json found, skipping");
        },
        Err(e) => error!(error = %e, "Error downloading user_candidates.json"),
    }

    // 4. Discover new sources via Gemini (if not processing user candidates)
    if all_sources.len() == initial_source_count {
        info!("Asking Gemini for new recommendations (Explorer mode)");
        let existing_names_for_gemini: HashSet<String> = all_sources.iter().map(|s| s.name.clone()).collect();
        let json_example = r#"[{"name": "Netflix TechBlog", "url": "https://netflixtechblog.com/feed"}]"#;
        let prompt = format!(
            "You are a Software Engineering Resource Scout. Your goal is to find high-quality, technical engineering blogs that publish regular, deep content.\n\nCurrent sources include: {:?}\n\nPlease recommend 3 NEW, different engineering blogs (company engineering blogs or high-profile individual blogs) that are NOT in this list.\nFor each recommendation, provide its RSS/Atom feed URL if you know it directly. Otherwise, provide the main website URL.\nReturn ONLY a valid JSON array of objects, where each object has 'name' and 'url'.\nExample: {}",
            existing_names_for_gemini, json_example
        );

        let response_text = call_gemini_with_retry(&http_client, &gemini_api_key, prompt).await?;

        let clean_json = response_text.trim()
            .trim_start_matches("```json")
            .trim_start_matches("```")
            .trim_end_matches("```")
            .trim();

        #[derive(Deserialize)]
        struct Recommendation {
            name: String,
            url: String,
        }

        let recommendations: Vec<Recommendation> = match serde_json::from_str(clean_json) {
            Ok(recs) => recs,
            Err(e) => {
                warn!(error = %e, raw_response = %clean_json, "Failed to parse Gemini JSON");
                Vec::new()
            }
        };

        info!(count = recommendations.len(), "Gemini recommended new sources");

        for rec in recommendations {
            let temp_source = SourceConfig { name: rec.name.clone(), source_type: "rss".to_string(), url: rec.url.clone() };
            if !all_sources.contains(&temp_source) {
                info!(name = %rec.name, url = %rec.url, "Investigating Gemini recommendation");
                match discover_and_validate_feed(&http_client, &gemini_api_key, &rec.url, &rec.name).await {
                    Ok(Some(validated_source)) => {
                        if !all_sources.contains(&validated_source) {
                            info!(
                                name = %validated_source.name,
                                url = %validated_source.url,
                                "Valid and relevant source found"
                            );
                            all_sources.insert(validated_source);
                        } else {
                            debug!(name = %rec.name, "Validated source already exists, skipping");
                        }
                    },
                    Ok(None) => debug!(name = %rec.name, "Invalid or irrelevant, skipping"),
                    Err(e) => warn!(name = %rec.name, error = %e, "Error processing Gemini recommendation"),
                }
            } else {
                debug!(name = %rec.name, "Gemini recommendation already exists, skipping");
            }
        }
    }

    // 5. Review existing sources for freshness
    info!(count = all_sources.len(), "Reviewing existing sources for freshness");
    let mut reviewed_sources = HashSet::new();
    let three_months_ago = Utc::now() - Duration::days(FRESHNESS_DAYS);

    for source in all_sources.iter() {
        // HN is always fresh - skip freshness check for it
        if source.source_type == "hackernews" {
            reviewed_sources.insert(source.clone());
            continue;
        }

        debug!(name = %source.name, url = %source.url, "Checking freshness");
        match fetch_latest_pub_date(&http_client, &source.url).await {
            Ok(Some(latest_date)) => {
                if latest_date > three_months_ago {
                    debug!(
                        name = %source.name,
                        last_post = %latest_date.format("%Y-%m-%d"),
                        "Source is fresh, keeping"
                    );
                    reviewed_sources.insert(source.clone());
                } else {
                    info!(
                        name = %source.name,
                        last_post = %latest_date.format("%Y-%m-%d"),
                        "Source is stale, removing"
                    );
                }
            },
            Ok(None) => {
                warn!(name = %source.name, "Could not determine freshness, removing");
            },
            Err(e) => {
                warn!(name = %source.name, error = %e, "Error checking freshness, removing");
            },
        }
    }

    // 6. Save Updated Sources
    let updated_sources_vec: Vec<SourceConfig> = reviewed_sources.into_iter().collect();
    let sources_changed = updated_sources_vec.len() != initial_source_count
        || !updated_sources_vec.iter().all(|s| current_sources.contains(s));

    if sources_changed {
        info!(
            total = updated_sources_vec.len(),
            "Updating sources.json in GCS"
        );
        let updated_json = serde_json::to_vec_pretty(&updated_sources_vec)?;

        gcs_client.upload_object(
            &UploadObjectRequest {
                bucket: bucket_name.to_string(),
                ..Default::default()
            },
            updated_json,
            &UploadType::Simple(Media::new("config/sources.json".to_string()))
        ).await?;
        info!("Successfully updated sources.json in GCS");
    } else {
        info!("No changes to sources.json");
    }

    info!("SE Explorer Agent completed successfully");
    Ok(())
}

#[instrument(skip(client, gemini_api_key), fields(source_name = %name, url_domain = %extract_domain(url)))]
async fn discover_and_validate_feed(client: &reqwest::Client, gemini_api_key: &str, url: &str, name: &str) -> Result<Option<SourceConfig>, Box<dyn std::error::Error + Send + Sync>> {
    let mut current_url_str = url.to_string();

    for _ in 0..MAX_FEED_DISCOVERY_ATTEMPTS {
        let res = client.get(&current_url_str).send().await?;
        let final_url_str = res.url().to_string();

        let content_type = res.headers().get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();

        let text = res.text().await?;

        let is_feed_content_type = content_type.contains("xml") || content_type.contains("rss") || content_type.contains("atom");
        let is_valid_feed = rss::Channel::read_from(text.as_bytes()).is_ok() || atom_syndication::Feed::read_from(text.as_bytes()).is_ok();

        if is_feed_content_type
            && is_valid_feed
            && is_relevant_with_gemini(client, gemini_api_key, name, &final_url_str, &text).await?
        {
            return Ok(Some(SourceConfig { name: name.to_string(), source_type: "rss".to_string(), url: final_url_str }));
        }

        // HTML Discovery
        let document = Document::from(text.as_str());
        for node in document.find(Name("link").and(Attr("rel", "alternate"))
                                   .and(Attr("type", "application/rss+xml")
                                        .or(Attr("type", "application/atom+xml")))) {
            if let Some(href) = node.attr("href") {
                let Ok(base_url) = Url::parse(&final_url_str) else { continue };
                let Ok(resolved_url) = base_url.join(href) else { continue };
                let resolved_url_str = resolved_url.to_string();

                // Check if feed exists (ignore HEAD failures)
                let head_result = client.head(&resolved_url_str).send().await;
                if let Ok(resp) = head_result {
                    if resp.status().is_success()
                        && is_relevant_with_gemini(client, gemini_api_key, name, &resolved_url_str, "").await.unwrap_or(false)
                    {
                        return Ok(Some(SourceConfig { name: name.to_string(), source_type: "rss".to_string(), url: resolved_url_str }));
                    }
                }
            }
        }

        // Try homepage if current_url is not a feed
        if let Ok(parsed_url) = Url::parse(&current_url_str) {
            let base_url = format!("{}://{}", parsed_url.scheme(), parsed_url.host_str().unwrap_or_default());
            if current_url_str != base_url {
                current_url_str = base_url;
                continue;
            }
        }
        break;
    }

    // Try common suffixes
    if let Ok(parsed_url) = Url::parse(url) {
        let base_domain = format!("{}://{}", parsed_url.scheme(), parsed_url.host_str().unwrap_or_default());
        let suffixes = ["/feed", "/rss", "/atom.xml", "/feed.xml", "/rss.xml"];
        for suffix in suffixes {
            let Ok(base) = Url::parse(&base_domain) else { continue };
            let Ok(candidate_url) = base.join(suffix) else { continue };
            let candidate_url_str = candidate_url.to_string();

            // Check if feed exists (ignore HEAD failures)
            let head_result = client.head(&candidate_url_str).send().await;
            if let Ok(resp) = head_result {
                if resp.status().is_success()
                    && is_relevant_with_gemini(client, gemini_api_key, name, &candidate_url_str, "").await.unwrap_or(false)
                {
                    return Ok(Some(SourceConfig { name: name.to_string(), source_type: "rss".to_string(), url: candidate_url_str }));
                }
            }
        }
    }
    Ok(None)
}

fn extract_domain(url: &str) -> String {
    url.split('/').nth(2).unwrap_or("unknown").to_string()
}

#[instrument(skip(client), fields(url_domain = %extract_domain(feed_url)))]
async fn fetch_latest_pub_date(client: &reqwest::Client, feed_url: &str) -> Result<Option<DateTime<Utc>>, Box<dyn std::error::Error + Send + Sync>> {
    let content = client.get(feed_url).send().await?.bytes().await?;

    // Try parsing as RSS
    if let Ok(channel) = Channel::read_from(&content[..]) {
        if let Some(latest_item) = channel.items().iter()
            .filter_map(|item| item.pub_date())
            .filter_map(|pub_date_str| DateTime::parse_from_rfc2822(pub_date_str).ok())
            .max_by_key(|dt| *dt)
        {
            return Ok(Some(latest_item.with_timezone(&Utc)));
        }
    }

    // Try parsing as Atom
    if let Ok(feed) = Feed::read_from(&content[..]) {
        if let Some(latest_entry) = feed.entries().iter()
            .map(|entry| {
                entry.published()
                    .map(|d| d.with_timezone(&Utc))
                    .unwrap_or_else(|| entry.updated().with_timezone(&Utc))
            })
            .max_by_key(|dt| *dt)
        {
            return Ok(Some(latest_entry));
        }
    }

    Ok(None)
}

#[instrument(skip(client, api_key, content_sample), fields(source_name = %name))]
async fn is_relevant_with_gemini(client: &reqwest::Client, api_key: &str, name: &str, url: &str, content_sample: &str) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
    let prompt = format!(
        "Given the blog titled '{}' at URL '{}', and a sample of its content: '{}'.\n\nDoes this source consistently publish high-quality, technically deep content relevant to a senior software engineer in 2025?\n\nRespond ONLY with 'yes' or 'no'.",
        name, url, content_sample
    );

    let response = call_gemini_with_retry(client, api_key, prompt).await?;
    Ok(response.trim().to_lowercase() == "yes")
}