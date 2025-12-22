use rss::Channel;
use atom_syndication::Feed as AtomFeed;
use serde::Deserialize;
use std::error::Error;
use std::time::Duration as StdDuration;
use chrono::{DateTime, Utc, Duration};
use tracing::{warn, debug};

// Re-export SourceConfig from gemini-engine for convenience
pub use gemini_engine::SourceConfig;

/// HTTP timeout for fetching feeds
const FETCH_TIMEOUT_SECS: u64 = 30;
/// Maximum number of items to fetch from each source
const MAX_ITEMS_PER_SOURCE: usize = 10;

#[derive(Debug, Clone)]
pub struct Article {
    pub title: String,
    pub url: String,
    pub source: String,
    #[allow(dead_code)] // Reserved for future filtering by date
    pub published_at: DateTime<Utc>,
}

// Hacker News Item Struct
#[derive(Deserialize, Debug)]
struct HnItem {
    title: Option<String>,
    url: Option<String>,
    time: i64,
    #[allow(dead_code)] // Required by HN API, may use for filtering in future
    r#type: String,
}

/// Create a shared HTTP client with configured timeout
pub fn create_http_client() -> Result<reqwest::Client, Box<dyn Error + Send + Sync>> {
    reqwest::Client::builder()
        .timeout(StdDuration::from_secs(FETCH_TIMEOUT_SECS))
        .build()
        .map_err(|e| e.into())
}

pub async fn fetch_from_source(source: &SourceConfig, client: &reqwest::Client) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    match source.source_type.as_str() {
        "rss" => fetch_rss(source, client).await,
        "atom" => fetch_atom(source, client).await,
        "hackernews" => fetch_hackernews(source, client).await,
        other => {
            Err(format!("Unknown source type: '{}' for source '{}'", other, source.name).into())
        }
    }
}

async fn fetch_rss(source: &SourceConfig, client: &reqwest::Client) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    let content = client.get(&source.url).send().await?.bytes().await?;
    let channel = Channel::read_from(&content[..])?;

    let mut articles = Vec::new();
    let yesterday = Utc::now() - Duration::hours(24);
    let mut skipped_dates = 0;

    for item in channel.items().iter().take(MAX_ITEMS_PER_SOURCE) {
        if let (Some(title), Some(link), Some(pub_date)) = (item.title(), item.link(), item.pub_date()) {
            // Parse date (RFC2822 usually) - log and skip articles with unparseable dates
            let parsed_date = match DateTime::parse_from_rfc2822(pub_date) {
                Ok(dt) => dt.with_timezone(&Utc),
                Err(_) => {
                    skipped_dates += 1;
                    continue;
                }
            };

            // Use >= to include articles from exactly 24 hours ago
            if parsed_date >= yesterday {
                articles.push(Article {
                    title: title.to_string(),
                    url: link.to_string(),
                    source: source.name.clone(),
                    published_at: parsed_date,
                });
            }
        }
    }

    if skipped_dates > 0 {
        warn!(source = %source.name, skipped = skipped_dates, "Skipped articles with unparseable dates");
    }
    debug!(source = %source.name, count = articles.len(), "Fetched RSS articles");

    Ok(articles)
}

async fn fetch_atom(source: &SourceConfig, client: &reqwest::Client) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    let content = client.get(&source.url).send().await?.text().await?;
    let feed = content.parse::<AtomFeed>()?;

    let mut articles = Vec::new();
    let yesterday = Utc::now() - Duration::hours(24);
    let mut skipped_dates = 0;

    for entry in feed.entries().iter().take(MAX_ITEMS_PER_SOURCE) {
        let title = entry.title().as_str();

        // Get the first link (usually the alternate/html link)
        let link = entry.links().first().map(|l| l.href());

        // Atom uses published or updated date
        let date_str = entry.published().or(Some(entry.updated()));

        if let (Some(link), Some(date)) = (link, date_str) {
            // Parse RFC3339 date
            let parsed_date = match DateTime::parse_from_rfc3339(&date.to_rfc3339()) {
                Ok(dt) => dt.with_timezone(&Utc),
                Err(_) => {
                    skipped_dates += 1;
                    continue;
                }
            };

            if parsed_date >= yesterday {
                articles.push(Article {
                    title: title.to_string(),
                    url: link.to_string(),
                    source: source.name.clone(),
                    published_at: parsed_date,
                });
            }
        }
    }

    if skipped_dates > 0 {
        warn!(source = %source.name, skipped = skipped_dates, "Skipped entries with unparseable dates");
    }
    debug!(source = %source.name, count = articles.len(), "Fetched Atom articles");

    Ok(articles)
}

async fn fetch_hackernews(source: &SourceConfig, client: &reqwest::Client) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    let top_ids: Vec<u32> = client.get(&source.url).send().await?.json().await?;

    let mut articles = Vec::new();
    let yesterday = Utc::now() - Duration::hours(24);
    let mut skipped_timestamps = 0;

    // Fetch top stories using the shared client
    for id in top_ids.iter().take(MAX_ITEMS_PER_SOURCE) {
        let url = format!("https://hacker-news.firebaseio.com/v0/item/{}.json", id);
        let resp = match client.get(&url).send().await {
            Ok(resp) => resp,
            Err(e) => {
                warn!(id = id, error = %e, "Failed to fetch HN item");
                continue;
            }
        };

        let item: HnItem = match resp.json().await {
            Ok(item) => item,
            Err(e) => {
                warn!(id = id, error = %e, "Failed to parse HN item");
                continue;
            }
        };

        if let (Some(title), Some(url)) = (item.title, item.url) {
            // HN time is unix timestamp
            let published_at = match DateTime::from_timestamp(item.time, 0) {
                Some(dt) => dt,
                None => {
                    skipped_timestamps += 1;
                    continue;
                }
            };

            // Apply same 24h freshness filter as RSS (>= to include boundary)
            if published_at >= yesterday {
                articles.push(Article {
                    title,
                    url,
                    source: source.name.clone(),
                    published_at,
                });
            }
        }
    }

    if skipped_timestamps > 0 {
        warn!(source = %source.name, skipped = skipped_timestamps, "Skipped items with invalid timestamps");
    }
    debug!(source = %source.name, count = articles.len(), "Fetched HackerNews articles");

    Ok(articles)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_article_struct() {
        let article = Article {
            title: "Test Article".to_string(),
            url: "https://example.com/article".to_string(),
            source: "Test Source".to_string(),
            published_at: Utc::now(),
        };

        assert_eq!(article.title, "Test Article");
        assert_eq!(article.url, "https://example.com/article");
        assert_eq!(article.source, "Test Source");
    }

    #[test]
    fn test_source_config_unknown_type() {
        let source = SourceConfig {
            name: "Unknown".to_string(),
            source_type: "unknown_type".to_string(),
            url: "https://example.com".to_string(),
        };

        // We can't easily test async fetch_from_source without a mock client,
        // but we can verify the source config is constructed correctly
        assert_eq!(source.source_type, "unknown_type");
    }

    #[test]
    fn test_create_http_client() {
        let client = create_http_client();
        assert!(client.is_ok(), "HTTP client should be created successfully");
    }
}
