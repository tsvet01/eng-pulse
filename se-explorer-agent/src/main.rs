use reqwest;
use serde::{Deserialize, Serialize};
use tokio;
use google_cloud_storage::client::{Client, ClientConfig};
use google_cloud_storage::http::objects::download::Range;
use google_cloud_storage::http::objects::get::GetObjectRequest;
use google_cloud_storage::http::objects::upload::{UploadObjectRequest, UploadType, Media};
use select::document::Document;
use select::predicate::{Name, Attr, Predicate};
use std::collections::HashSet;
use url::Url;
use chrono::{DateTime, Utc, Duration}; // For date checking
use rss::Channel;
use atom_syndication::Feed;

// --- Configuration Structs ---
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq, Hash)]
pub struct SourceConfig {
    pub name: String,
    pub r#type: String, // "hackernews" or "rss"
    pub url: String,
}

// --- Gemini Structs ---
#[derive(Serialize, Deserialize, Debug)]
struct GeminiPart {
    text: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct GeminiContent {
    parts: Vec<GeminiPart>,
}

#[derive(Serialize, Deserialize, Debug)]
struct GeminiRequest {
    contents: Vec<GeminiContent>,
}

#[derive(Deserialize, Debug)]
struct GeminiCandidate {
    content: GeminiContent,
}

#[derive(Deserialize, Debug)]
struct GeminiResponse {
    candidates: Option<Vec<GeminiCandidate>>,
    error: Option<GeminiError>,
}

#[derive(Deserialize, Debug)]
struct GeminiError {
    message: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenv::dotenv().ok();
    let gemini_api_key = std::env::var("GEMINI_API_KEY").expect("GEMINI_API_KEY not set");
    let bucket_name = "tsvet01-agent-brain";

    // 1. Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);
    let http_client = reqwest::Client::new(); // Re-use for feed fetching

    // 2. Load Current Sources
    println!("Downloading current sources from gs://{}/config/sources.json...", bucket_name);
    let sources_data = gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: "config/sources.json".to_string(),
            ..Default::default()
        },
        &Range::default()
    ).await?;
    let mut current_sources: Vec<SourceConfig> = serde_json::from_slice(&sources_data)?;
    println!("Loaded {} current sources.", current_sources.len());

    let mut all_sources: HashSet<SourceConfig> = current_sources.drain(..).collect(); // Use a HashSet to manage unique sources

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
            println!("Found user_candidates.json. Processing {} new sources...", user_candidates_object_name);
            let user_recs: Vec<SourceConfig> = serde_json::from_slice(&candidates_data)?;

            for rec in user_recs {
                // Ensure no duplicates from user list or existing sources
                if !all_sources.contains(&rec) {
                    println!("  -> Investigating user candidate: {} ({})", rec.name, rec.url);
                    match discover_and_validate_feed(&http_client, &gemini_api_key, &rec.url, &rec.name).await {
                        Ok(Some(validated_source)) => {
                            if !all_sources.contains(&validated_source) { // Final check for duplicates before adding
                                println!("    -> Valid and relevant: {} ({})", validated_source.name, validated_source.url);
                                all_sources.insert(validated_source);
                            } else {
                                println!("    -> Validated source already exists. Skipping.");
                            }
                        },
                        Ok(None) => println!("    -> Invalid or irrelevant. Skipping."),
                        Err(e) => eprintln!("    -> Error processing candidate {}: {}", rec.name, e),
                    }
                } else {
                    println!("  -> User candidate {} already exists. Skipping.", rec.name);
                }
            }
            // Delete user_candidates.json after processing
            println!("Deleting {} from GCS...", user_candidates_object_name);
            gcs_client.delete_object(
                &google_cloud_storage::http::objects::delete::DeleteObjectRequest {
                    bucket: bucket_name.to_string(),
                    object: user_candidates_object_name.to_string(),
                    ..Default::default()
                }
            ).await?;
        },
        Err(e) if e.to_string().contains("No such object") => println!("No user_candidates.json found. Skipping."),
        Err(e) => eprintln!("Error downloading user_candidates.json: {}", e),
    }

    // 4. Discover new sources via Gemini (if not processing user candidates)
    // Only ask Gemini if no user candidates were processed or added OR if all_sources is still less than current_sources + some threshold
    // To prevent asking Gemini for *new* sources every time if there are existing ones to clean up,
    // we should run the discovery only if no user candidates were processed or if the existing sources list is already "too short".
    // For now, let's keep it simple: if user candidates were just processed, don't ask Gemini.
    if all_sources.len() == current_sources.len() { // This condition implies no new user candidates were added
        println!("\nAsking Gemini for new recommendations (Explorer mode)...");
        let existing_names_for_gemini: HashSet<String> = all_sources.iter().map(|s| s.name.clone()).collect();
        let json_example = r#"[{"name": "Netflix TechBlog", "url": "https://netflixtechblog.com/feed"}]"#;
        let prompt = format!(
            "You are a Software Engineering Resource Scout. Your goal is to find high-quality, technical engineering blogs that publish regular, deep content.\n\n\x01Current sources include: {:?}\n\n\x01Please recommend 3 NEW, different engineering blogs (company engineering blogs or high-profile individual blogs) that are NOT in this list.\n\x01For each recommendation, provide its RSS/Atom feed URL if you know it directly. Otherwise, provide the main website URL.\n\x01Return ONLY a valid JSON array of objects, where each object has 'name' and 'url'. \n\x01Example: {}",
            existing_names_for_gemini, json_example
        );

        let response_text = call_gemini(&gemini_api_key, prompt).await?;
        
        let clean_json = response_text.trim()
            .trim_start_matches("```json")
            .trim_start_matches("```")
            .trim_end_matches("```");

        #[derive(Deserialize)]
        struct Recommendation {
            name: String,
            url: String,
        }

        let recommendations: Vec<Recommendation> = serde_json::from_str(clean_json)
            .map_err(|e| format!("Failed to parse Gemini JSON: {}. Raw: {}", e, clean_json))?;

        println!("Gemini recommended {} new sources.", recommendations.len());

        for rec in recommendations {
            let temp_source = SourceConfig { name: rec.name.clone(), r#type: "rss".to_string(), url: rec.url.clone() };
            if !all_sources.contains(&temp_source) {
                println!("  -> Investigating Gemini recommendation: {} ({})", rec.name, rec.url);
                match discover_and_validate_feed(&http_client, &gemini_api_key, &rec.url, &rec.name).await {
                    Ok(Some(validated_source)) => {
                        if !all_sources.contains(&validated_source) {
                            println!("    -> Valid and relevant: {} ({})", validated_source.name, validated_source.url);
                            all_sources.insert(validated_source);
                        } else {
                            println!("    -> Validated source already exists. Skipping.");
                        }
                    },
                    Ok(None) => println!("    -> Invalid or irrelevant. Skipping."),
                    Err(e) => eprintln!("    -> Error processing Gemini recommendation {}: {}", rec.name, e),
                }
            } else {
                println!("  -> Gemini recommendation {} already exists. Skipping.", rec.name);
            }
        }
    }

    // 5. Review existing sources for freshness
    println!("\nReviewing {} existing sources for freshness...", all_sources.len());
    let mut reviewed_sources = HashSet::new();
    let three_months_ago = Utc::now() - Duration::days(90);

    // Keep HN in the list if it was there originally
    if let Some(hn_source) = current_sources.iter().find(|s| s.r#type == "hackernews") {
        reviewed_sources.insert(hn_source.clone());
    }

    for source in all_sources.iter() {
        if source.r#type == "hackernews" { // Already handled or will be handled
            continue;
        }

        println!("  -> Checking freshness for: {} ({})", source.name, source.url);
        match fetch_latest_pub_date(&http_client, &source.url).await {
            Ok(Some(latest_date)) => {
                if latest_date > three_months_ago {
                    println!("    -> Fresh (last post: {}). Keeping.", latest_date.format("%Y-%m-%d"));
                    reviewed_sources.insert(source.clone());
                } else {
                    println!("    -> Stale (last post: {}). Removing.", latest_date.format("%Y-%m-%d"));
                }
            },
            Ok(None) => println!("    -> Could not determine freshness or invalid feed. Removing."),
            Err(e) => eprintln!("    -> Error checking freshness for {}: {}. Removing.", source.name, e),
        }
    }

    // 6. Save Updated Sources
    let updated_sources_vec: Vec<SourceConfig> = reviewed_sources.into_iter().collect();
    // Only update if there are actual changes
    if updated_sources_vec.len() != current_sources.len() || !updated_sources_vec.iter().all(|s| current_sources.contains(s)) {
        println!("\nUpdating sources.json in GCS ({} total sources)...", updated_sources_vec.len());
        let updated_json = serde_json::to_vec_pretty(&updated_sources_vec)?;
        
        gcs_client.upload_object(
            &UploadObjectRequest {
                bucket: bucket_name.to_string(),
                ..Default::default()
            },
            updated_json,
            &UploadType::Simple(Media::new("config/sources.json".to_string()))
        ).await?;
        println!("Successfully updated sources.json in GCS!");
    } else {
        println!("\nNo changes to sources.json.");
    }

    Ok(())
}

async fn discover_and_validate_feed(client: &reqwest::Client, gemini_api_key: &str, url: &str, name: &str) -> Result<Option<SourceConfig>, Box<dyn std::error::Error>> {
    let mut current_url_str = url.to_string();

    for _ in 0..2 { // Try original URL and then its homepage if needed
        let res = client.get(&current_url_str).send().await?;
        let final_url_str = res.url().to_string();

        let content_type = res.headers().get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        
        let text = res.text().await?;

        // 1. Check if the URL itself is a feed
        if content_type.contains("xml") || content_type.contains("rss") || content_type.contains("atom") {
            if rss::Channel::read_from(text.as_bytes()).is_ok() || atom_syndication::Feed::read_from(text.as_bytes()).is_ok() {
                // If it's a feed, validate its relevance with Gemini
                if is_relevant_with_gemini(gemini_api_key, name, &final_url_str, &text).await? {
                    return Ok(Some(SourceConfig { name: name.to_string(), r#type: "rss".to_string(), url: final_url_str }));
                }
            }
        }

        // 2. HTML Discovery
        let document = Document::from(text.as_str());
        for node in document.find(Name("link").and(Attr("rel", "alternate"))
                                   .and(Attr("type", "application/rss+xml")
                                        .or(Attr("type", "application/atom+xml")))) {
            if let Some(href) = node.attr("href") {
                if let Ok(base_url) = Url::parse(&final_url_str) {
                    if let Ok(resolved_url) = base_url.join(href) {
                        let resolved_url_str = resolved_url.to_string();
                        if client.head(&resolved_url_str).send().await?.status().is_success() {
                             // Validate relevance for discovered feeds
                            if is_relevant_with_gemini(gemini_api_key, name, &resolved_url_str, "").await? { // Pass empty content, only URL/name
                                return Ok(Some(SourceConfig { name: name.to_string(), r#type: "rss".to_string(), url: resolved_url_str }));
                            }
                        }
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

    // 3. Try common suffixes
    if let Ok(parsed_url) = Url::parse(url) {
        let base_domain = format!("{}://{}", parsed_url.scheme(), parsed_url.host_str().unwrap_or_default());
        let suffixes = ["/feed", "/rss", "/atom.xml", "/feed.xml", "/rss.xml"];
        for suffix in suffixes {
            if let Ok(candidate_url) = Url::parse(&base_domain)?.join(suffix) {
                let candidate_url_str = candidate_url.to_string();
                if client.head(&candidate_url_str).send().await?.status().is_success() {
                    // Validate relevance for discovered feeds
                    if is_relevant_with_gemini(gemini_api_key, name, &candidate_url_str, "").await? { // Pass empty content, only URL/name
                        return Ok(Some(SourceConfig { name: name.to_string(), r#type: "rss".to_string(), url: candidate_url_str }));
                    }
                }
            }
        }
    }
    Ok(None)
}

// Helper to fetch the latest publish date from a feed
async fn fetch_latest_pub_date(client: &reqwest::Client, feed_url: &str) -> Result<Option<DateTime<Utc>>, Box<dyn std::error::Error>> {
    let content = client.get(feed_url).send().await?.bytes().await?;

    // Try parsing as RSS
    if let Ok(channel) = Channel::read_from(&content[..]) {
        if let Some(latest_item) = channel.items().iter()
            .filter_map(|item| item.pub_date())
            .filter_map(|pub_date_str| DateTime::parse_from_rfc2822(pub_date_str).ok())
            .max_by_key(|dt| *dt) // Use the DateTime object directly for comparison
        {
            return Ok(Some(latest_item.with_timezone(&Utc)));
        }
    }

    // Try parsing as Atom
    if let Ok(feed) = Feed::read_from(&content[..]) {
        if let Some(latest_entry) = feed.entries().iter()
            .filter_map(|entry| {
                if let Some(published_date) = entry.published() {
                    Some(published_date.with_timezone(&Utc)) // Convert to Utc
                } else {
                    // If published is None, use updated_date which is a direct reference
                    Some(entry.updated().with_timezone(&Utc)) // Convert to Utc
                }
            })
            .max_by_key(|dt| *dt)
        {
            return Ok(Some(latest_entry));
        }
    }

    Ok(None)
}

// Helper to ask Gemini about relevance
async fn is_relevant_with_gemini(api_key: &str, name: &str, url: &str, content_sample: &str) -> Result<bool, Box<dyn std::error::Error>> {
    let prompt = format!(
        "Given the blog titled '{}' at URL '{}', and a sample of its content: '{}'.\n\nDoes this source consistently publish high-quality, technically deep content relevant to a senior software engineer in 2025?\n\nRespond ONLY with 'yes' or 'no'.",
        name, url, content_sample
    );
    
    let response = call_gemini(api_key, prompt).await?;
    Ok(response.trim().to_lowercase() == "yes")
}


async fn call_gemini(api_key: &str, text: String) -> Result<String, Box<dyn std::error::Error>> {
    let url = format!("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key={}", api_key);
    
    let request = GeminiRequest {
        contents: vec![
            GeminiContent {
                parts: vec![ GeminiPart { text } ]
            }
        ]
    };

    let client = reqwest::Client::new();
    let res = client.post(&url)
        .json(&request)
        .send()
        .await?;

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