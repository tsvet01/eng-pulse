mod fetcher;

use reqwest;
use serde::{Deserialize, Serialize};
use tokio;
use readabilityrs::Readability;
use crate::fetcher::{SourceConfig, Article};
use google_cloud_storage::client::{Client, ClientConfig};
use google_cloud_storage::http::objects::download::Range;
use google_cloud_storage::http::objects::get::GetObjectRequest;
use google_cloud_storage::http::objects::upload::{UploadObjectRequest, UploadType, Media};
use chrono::Utc;

// --- Gemini Structs ---
#[derive(Serialize, Deserialize, Debug)]
struct GeminiPart {
    text: String,
}

#[derive(Serialize, Deserialize, Debug)]
struct GeminiContent {
    parts: Vec<GeminiPart>,
}

#[derive(Serialize, Debug)]
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

// --- Main ---

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenv::dotenv().ok();
    // Allow GEMINI_API_KEY to be missing if we just want to test GCS (optional, but sticking to strict for now)
    let gemini_api_key = std::env::var("GEMINI_API_KEY").expect("GEMINI_API_KEY not set");
    let bucket_name = "tsvet01-agent-brain"; // Hardcoded for now, or use env var

    // 0. Initialize GCS Client
    let config = ClientConfig::default().with_auth().await?;
    let gcs_client = Client::new(config);

    println!("Using GCS Bucket: {}", bucket_name);

    // 1. Load Sources from GCS
    println!("Fetching sources.json from GCS...");
    let sources_data = gcs_client.download_object(
        &GetObjectRequest {
            bucket: bucket_name.to_string(),
            object: "config/sources.json".to_string(),
            ..Default::default()
        },
        &Range::default()
    ).await?;

    let sources: Vec<SourceConfig> = serde_json::from_slice(&sources_data)?;
    println!("Loaded {} sources from Cloud Storage.", sources.len());


    // 2. Fetch Articles
    println!("Fetching headlines...");
    let mut all_articles: Vec<Article> = Vec::new();
    for source in sources {
        print!("  - {}: ", source.name);
        match fetcher::fetch_from_source(&source).await {
            Ok(mut articles) => {
                println!("found {}", articles.len());
                all_articles.append(&mut articles);
            },
            Err(e) => println!("Error: {}", e),
        }
    }

    if all_articles.is_empty() {
        println!("No recent articles found.");
        return Ok(());
    }

    // 3. Selection
    println!("\nAsking Gemini to select the best article from {} candidates...", all_articles.len());
    
    let mut articles_text = String::new();
    for (i, article) in all_articles.iter().enumerate() {
        articles_text.push_str(&format!( "{}. [{}] {}\n", i, article.source, article.title));
    }

    let selection_prompt = format!(
        "You are an expert Software Engineering Editor. Review the following list of article headlines collected today. Select the SINGLE most valuable, educational, and impactful article for a senior software engineer to read. Consider technical depth, novelty, and broad relevance.\n\n{}\n\nReply ONLY with the integer index number of the chosen article (e.g., '3'). Do not add any explanation.",
        articles_text
    );

    let selected_index = call_gemini(&gemini_api_key, selection_prompt).await?;
    let index: usize = selected_index.trim().parse().unwrap_or(0);

    let best_article = &all_articles[if index < all_articles.len() { index } else { 0 }];

    println!("\n*** Selected Article ***");
    println!("Title: {}", best_article.title);
    println!("URL: {}", best_article.url);

    // 4. Summarize
    println!("\nScraping and Summarizing...");
    
    let html_content = reqwest::get(&best_article.url).await?.text().await?;
    let product = Readability::new(
        html_content.as_str(),
        Some(&best_article.url),
        None
    )?.parse();

    let article_text = match product {
        Some(a) => a.content.unwrap_or_default(),
        None => format!("Title: {}, URL: {}", best_article.title, best_article.url)
    };

    let truncated_text = if article_text.len() > 50000 {
        &article_text[..50000]
    } else {
        &article_text
    };

    let summary_prompt = format!(
        "Please summarize the following software engineering article in a compact and educational format. Focus on key takeaways, core concepts, and why it matters to a software engineer. Ignore any promotional or fluff content.\n\nArticle Source: {}\nTitle: {}\nContent: {}",
        best_article.source, best_article.title, truncated_text
    );


    let summary = call_gemini(&gemini_api_key, summary_prompt).await?;

    println!("\n--- Daily SE Briefing ---");
    println!("{}", summary);

    // 5. Upload Summary to GCS
    let today = Utc::now().format("%Y-%m-%d").to_string();
    let object_name = format!("summaries/{}.md", today);
    let summary_bytes = summary.into_bytes();

    println!("\nUploading summary to GCS: gs://{}/{}", bucket_name, object_name);
    
    let upload_type = UploadType::Simple(Media::new(object_name.clone()));
    let _uploaded = gcs_client.upload_object(
        &UploadObjectRequest {
            bucket: bucket_name.to_string(),
            ..Default::default()
        },
        summary_bytes,
        &upload_type
    ).await?;

    println!("Upload complete!");

    Ok(())
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
