use reqwest;
use rss::Channel;
use serde::Deserialize;
use std::error::Error;
use chrono::{DateTime, Utc, Duration};

#[derive(Debug, Clone)]
pub struct Article {
    pub title: String,
    pub url: String,
    pub source: String,
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
    r#type: String,
}

pub async fn fetch_from_source(source: &SourceConfig) -> Result<Vec<Article>, Box<dyn Error>> {
    match source.r#type.as_str() {
        "rss" => fetch_rss(source).await,
        "hackernews" => fetch_hackernews(source).await,
        _ => {
            eprintln!("Unknown source type: {}", source.r#type);
            Ok(vec![])
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
            // Parse date (RFC2822 usually)
            let parsed_date = DateTime::parse_from_rfc2822(pub_date)
                .map(|dt| dt.with_timezone(&Utc))
                .or_else(|_| {
                    // Try generic parsing or current time fallback if parsing fails (simple for now)
                    Ok::<DateTime<Utc>, chrono::ParseError>(Utc::now()) 
                })?;

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
    
    // Check top 10 stories to find good ones
    let mut articles = Vec::new();
    let client = reqwest::Client::new();

    for id in top_ids.iter().take(10) {
        let url = format!("https://hacker-news.firebaseio.com/v0/item/{}.json", id);
        let item: HnItem = client.get(&url).send().await?.json().await?;

        if let (Some(title), Some(url)) = (item.title, item.url) {
            // HN time is unix timestamp
            let published_at = DateTime::from_timestamp(item.time, 0)
                .unwrap_or_else(|| Utc::now());
            
            // Just take them regardless of strict 24h check (Top stories are usually recent enough)
            articles.push(Article {
                title,
                url,
                source: "Hacker News".to_string(),
                published_at,
            });
        }
    }

    Ok(articles)
}
