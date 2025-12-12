use rss::Channel;
use serde::Deserialize;
use std::error::Error;
use chrono::{DateTime, Utc, Duration};

#[derive(Debug, Clone)]
pub struct Article {
    pub title: String,
    pub url: String,
    pub source: String,
    #[allow(dead_code)] // Reserved for future filtering by date
    pub published_at: DateTime<Utc>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SourceConfig {
    pub name: String,
    pub r#type: String, // "hackernews" or "rss"
    pub url: String,
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

pub async fn fetch_from_source(source: &SourceConfig) -> Result<Vec<Article>, Box<dyn Error>> {
    match source.r#type.as_str() {
        "rss" => fetch_rss(source).await,
        "hackernews" => fetch_hackernews(source).await,
        other => {
            Err(format!("Unknown source type: '{}' for source '{}'", other, source.name).into())
        }
    }
}

async fn fetch_rss(source: &SourceConfig) -> Result<Vec<Article>, Box<dyn Error>> {
    let content = reqwest::get(&source.url).await?.bytes().await?;
    let channel = Channel::read_from(&content[..])?;
    
    let mut articles = Vec::new();
    let yesterday = Utc::now() - Duration::hours(24);

    for item in channel.items().iter().take(10) {
        if let (Some(title), Some(link), Some(pub_date)) = (item.title(), item.link(), item.pub_date()) {
            // Parse date (RFC2822 usually) - skip articles with unparseable dates
            let parsed_date = match DateTime::parse_from_rfc2822(pub_date) {
                Ok(dt) => dt.with_timezone(&Utc),
                Err(_) => continue, // Skip articles with invalid dates
            };

            if parsed_date > yesterday {
                articles.push(Article {
                    title: title.to_string(),
                    url: link.to_string(),
                    source: source.name.clone(),
                    published_at: parsed_date,
                });
            }
        }
    }
    Ok(articles)
}

async fn fetch_hackernews(source: &SourceConfig) -> Result<Vec<Article>, Box<dyn Error>> {
    let top_ids: Vec<u32> = reqwest::get(&source.url).await?.json().await?;

    let mut articles = Vec::new();
    let client = reqwest::Client::new();
    let yesterday = Utc::now() - Duration::hours(24);

    // Fetch top 10 stories
    for id in top_ids.iter().take(10) {
        let url = format!("https://hacker-news.firebaseio.com/v0/item/{}.json", id);
        let item: HnItem = client.get(&url).send().await?.json().await?;

        if let (Some(title), Some(url)) = (item.title, item.url) {
            // HN time is unix timestamp
            let published_at = match DateTime::from_timestamp(item.time, 0) {
                Some(dt) => dt,
                None => continue, // Skip items with invalid timestamps
            };

            // Apply same 24h freshness filter as RSS
            if published_at > yesterday {
                articles.push(Article {
                    title,
                    url,
                    source: source.name.clone(),
                    published_at,
                });
            }
        }
    }

    Ok(articles)
}
