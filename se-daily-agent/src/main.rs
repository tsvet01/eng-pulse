mod fetcher;

use serde::{Deserialize, Serialize};
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
use gemini_engine::{call_gemini_with_retry, init_logging, extract_domain};

// --- Configuration Constants ---
const HTTP_TIMEOUT_SECS: u64 = 60;
const MAX_ARTICLE_CHARS: usize = 50_000;
const SUMMARY_SNIPPET_CHARS: usize = 100;
const DEFAULT_BUCKET: &str = "tsvet01-agent-brain";

// --- Manifest Struct ---
#[derive(Serialize, Deserialize, Debug, Clone)]
struct ManifestEntry {
    date: String,
    url: String,
    title: String,
    summary_snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    original_url: Option<String>,
}

// --- Main ---

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    dotenv::dotenv().ok();
    init_logging();

    let gemini_api_key = std::env::var("GEMINI_API_KEY").map_err(|_| {
        error!("GEMINI_API_KEY environment variable not set");
        "GEMINI_API_KEY environment variable not set"
    })?;
    let bucket_name = std::env::var("GCS_BUCKET").unwrap_or_else(|_| DEFAULT_BUCKET.to_string());

    info!(bucket = %bucket_name, "Starting SE Daily Agent");

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

    // 3. Selection
    info!("Asking Gemini to select best article");

    let mut articles_text = String::new();
    for (i, article) in all_articles.iter().enumerate() {
        articles_text.push_str(&format!("{}. [{}] {}\n", i, article.source, article.title));
    }

    let selection_prompt = format!(
        "You are an expert Software Engineering Editor. Review the following list of article headlines collected today. Select the SINGLE most valuable, educational, and impactful article for a senior software engineer to read. Consider technical depth, novelty, and broad relevance.\n\n{}\n\nReply ONLY with the integer index number of the chosen article (e.g., '3'). Do not add any explanation.",
        articles_text
    );

    let selected_index = call_gemini_with_retry(&http_client, &gemini_api_key, selection_prompt).await?;

    // Parse the index - extract first contiguous digit sequence only
    let index: usize = selected_index
        .trim()
        .chars()
        .skip_while(|c| !c.is_ascii_digit())
        .take_while(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse()
        .map_err(|e| {
            format!("Failed to parse Gemini selection '{}': {}", selected_index.trim(), e)
        })?;

    // Validate index is within bounds (all_articles cannot be empty - we return early above)
    let safe_index = if index >= all_articles.len() {
        warn!(
            returned_index = index,
            total_articles = all_articles.len(),
            "Gemini returned invalid index, using first article"
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

    // 4. Summarize
    info!("Scraping and summarizing article");

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

    let summary = call_gemini_with_retry(&http_client, &gemini_api_key, summary_prompt).await?;

    info!("Summary generated successfully");
    debug!(summary_length = summary.len(), "Summary details");

    // Create snippet BEFORE moving summary
    let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();

    // 5. Upload Summary to GCS
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let object_name = format!("summaries/{}.md", today);
    let summary_bytes = summary.into_bytes();

    info!(object = %object_name, "Uploading summary to GCS");

    let upload_type = UploadType::Simple(Media::new(object_name.clone()));
    let _uploaded = gcs_client.upload_object(
        &UploadObjectRequest {
            bucket: bucket_name.to_string(),
            ..Default::default()
        },
        summary_bytes,
        &upload_type
    ).await?;

    info!("Summary upload complete");

    // 6. Update Manifest
    info!("Updating manifest.json");
    let manifest_obj_name = "manifest.json";
    let public_url = format!("https://storage.googleapis.com/{}/{}", bucket_name, object_name);

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
        Err(e) if e.to_string().contains("No such object") => {
            info!("No existing manifest.json found, creating new one");
            Vec::new()
        },
        Err(e) => {
            return Err(format!("Failed to download manifest.json: {}", e).into());
        }
    };

    // Remove existing entry for today if any (to update it)
    manifest.retain(|e| e.date != today);

    // Add new entry
    manifest.insert(0, ManifestEntry {
        date: today.clone(),
        url: public_url,
        title: best_article.title.clone(),
        summary_snippet,
        original_url: Some(best_article.url.clone()),
    });

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
