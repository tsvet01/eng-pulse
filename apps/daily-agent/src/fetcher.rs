use atom_syndication::Feed as AtomFeed;
use chrono::{DateTime, Duration, Utc};
use rss::Channel;
use serde::Deserialize;
use std::error::Error;
use std::time::Duration as StdDuration;
use tracing::{debug, warn};

// Re-export from llm-client for convenience
pub use llm_client::{SourceConfig, SourceType};

/// HTTP timeout for fetching feeds
const FETCH_TIMEOUT_SECS: u64 = 30;
/// Maximum number of items to fetch from each source
const MAX_ITEMS_PER_SOURCE: usize = 10;

#[derive(Debug, Clone)]
pub struct Article {
    pub title: String,
    pub url: String,
    pub source: String,
    /// Populated for every article; the publish-date filtering is applied at
    /// fetch time (see `FetchWindow`), so the stored value itself is currently
    /// unread outside this module.
    #[allow(dead_code)]
    pub published_at: DateTime<Utc>,
}

/// Time window used to filter fetched articles by their publish date.
///
/// Normal daily runs keep articles from the last 24 hours (no upper bound).
/// Backfill runs (`--date`) restrict to a single UTC calendar day, so an article
/// is matched only if it was *actually* published that day — never fabricated
/// from whatever the feed currently holds.
#[derive(Debug, Clone, Copy)]
pub struct FetchWindow {
    pub start: DateTime<Utc>,
    /// Exclusive upper bound. `None` means "everything since `start`".
    pub end: Option<DateTime<Utc>>,
}

impl FetchWindow {
    /// Articles published within the last 24 hours (default daily behavior).
    pub fn last_24h() -> Self {
        FetchWindow {
            start: Utc::now() - Duration::hours(24),
            end: None,
        }
    }

    /// A single UTC calendar day `[date 00:00, date+1 00:00)` — used for backfill.
    pub fn day(date: chrono::NaiveDate) -> Self {
        let start = date.and_hms_opt(0, 0, 0).expect("valid midnight").and_utc();
        FetchWindow {
            start,
            end: Some(start + Duration::hours(24)),
        }
    }

    /// True if `ts` falls within this window.
    pub fn contains(&self, ts: DateTime<Utc>) -> bool {
        ts >= self.start && self.end.is_none_or(|end| ts < end)
    }
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

pub async fn fetch_from_source(
    source: &SourceConfig,
    client: &reqwest::Client,
    window: FetchWindow,
) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    match source.source_type {
        SourceType::Rss => fetch_rss(source, client, window).await,
        SourceType::Atom => fetch_atom(source, client, window).await,
        SourceType::HackerNews => fetch_hackernews(source, client, window).await,
    }
}

/// Try to parse various date formats commonly found in RSS feeds
fn parse_rss_date(date_str: &str) -> Option<DateTime<Utc>> {
    // Try RFC2822 first (standard RSS format)
    if let Ok(dt) = DateTime::parse_from_rfc2822(date_str) {
        return Some(dt.with_timezone(&Utc));
    }

    // Try ThoughtWorks format: "Tue Nov 18 00:00:00 UTC 2025"
    if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(date_str, "%a %b %d %H:%M:%S UTC %Y") {
        return Some(dt.and_utc());
    }

    // Try ISO 8601 / RFC3339
    if let Ok(dt) = DateTime::parse_from_rfc3339(date_str) {
        return Some(dt.with_timezone(&Utc));
    }

    None
}

async fn fetch_rss(
    source: &SourceConfig,
    client: &reqwest::Client,
    window: FetchWindow,
) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    let content = client.get(&source.url).send().await?.bytes().await?;
    let channel = Channel::read_from(&content[..])?;

    let mut articles = Vec::new();
    let mut skipped_dates = 0;

    for item in channel.items().iter().take(MAX_ITEMS_PER_SOURCE) {
        if let (Some(title), Some(link), Some(pub_date)) =
            (item.title(), item.link(), item.pub_date())
        {
            // Parse date using multiple format attempts
            let parsed_date = match parse_rss_date(pub_date) {
                Some(dt) => dt,
                None => {
                    skipped_dates += 1;
                    continue;
                }
            };

            if window.contains(parsed_date) {
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

async fn fetch_atom(
    source: &SourceConfig,
    client: &reqwest::Client,
    window: FetchWindow,
) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    let content = client.get(&source.url).send().await?.text().await?;
    let feed = content.parse::<AtomFeed>()?;

    let mut articles = Vec::new();
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

            if window.contains(parsed_date) {
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

async fn fetch_hackernews(
    source: &SourceConfig,
    client: &reqwest::Client,
    window: FetchWindow,
) -> Result<Vec<Article>, Box<dyn Error + Send + Sync>> {
    let top_ids: Vec<u32> = client.get(&source.url).send().await?.json().await?;

    let mut articles = Vec::new();
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

            // Apply the same publish-date window as RSS/Atom
            if window.contains(published_at) {
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
    use chrono::{Datelike, Timelike};

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
    fn test_create_http_client() {
        let client = create_http_client();
        assert!(client.is_ok(), "HTTP client should be created successfully");
    }

    #[test]
    fn test_fetch_window_last_24h_has_no_upper_bound() {
        let w = FetchWindow::last_24h();
        assert!(w.end.is_none(), "daily window should have no upper bound");
        assert!(w.contains(Utc::now()));
        assert!(!w.contains(Utc::now() - Duration::hours(25)));
    }

    #[test]
    fn test_fetch_window_day_is_single_utc_calendar_day() {
        let d = chrono::NaiveDate::from_ymd_opt(2026, 5, 26).unwrap();
        let w = FetchWindow::day(d);
        // Start and end of the target day are included.
        assert!(w.contains(d.and_hms_opt(0, 0, 0).unwrap().and_utc()));
        assert!(w.contains(d.and_hms_opt(23, 59, 59).unwrap().and_utc()));
        // The next day is excluded (upper bound is exclusive).
        assert!(!w.contains(
            (d + Duration::days(1))
                .and_hms_opt(0, 0, 0)
                .unwrap()
                .and_utc()
        ));
        // The previous day is excluded.
        assert!(!w.contains(
            (d - Duration::days(1))
                .and_hms_opt(12, 0, 0)
                .unwrap()
                .and_utc()
        ));
    }

    #[test]
    fn test_parse_rss_date_rfc2822() {
        // Standard RSS format
        let date = parse_rss_date("Tue, 18 Nov 2025 00:00:00 +0000");
        assert!(date.is_some());
        let dt = date.unwrap();
        assert_eq!(dt.year(), 2025);
        assert_eq!(dt.month(), 11);
        assert_eq!(dt.day(), 18);
    }

    #[test]
    fn test_parse_rss_date_thoughtworks_format() {
        // ThoughtWorks custom format: "Tue Nov 18 00:00:00 UTC 2025"
        let date = parse_rss_date("Tue Nov 18 00:00:00 UTC 2025");
        assert!(date.is_some());
        let dt = date.unwrap();
        assert_eq!(dt.year(), 2025);
        assert_eq!(dt.month(), 11);
        assert_eq!(dt.day(), 18);
    }

    #[test]
    fn test_parse_rss_date_rfc3339() {
        // ISO 8601 / RFC3339 format
        let date = parse_rss_date("2025-11-18T00:00:00+00:00");
        assert!(date.is_some());
        let dt = date.unwrap();
        assert_eq!(dt.year(), 2025);
        assert_eq!(dt.month(), 11);
        assert_eq!(dt.day(), 18);
    }

    #[test]
    fn test_parse_rss_date_invalid() {
        assert!(parse_rss_date("not a date").is_none());
        assert!(parse_rss_date("").is_none());
        assert!(parse_rss_date("2025-13-45").is_none());
    }

    #[test]
    fn test_parse_rss_date_positive_timezone_offset() {
        let date = parse_rss_date("Wed, 25 Dec 2024 10:00:00 +0530");
        assert!(date.is_some());
        let dt = date.unwrap();
        assert_eq!(dt.year(), 2024);
        assert_eq!(dt.month(), 12);
        assert_eq!(dt.day(), 25);
        // +0530 means 10:00 IST = 04:30 UTC
        assert_eq!(dt.hour(), 4);
        assert_eq!(dt.minute(), 30);
    }

    #[test]
    fn test_parse_rss_date_negative_timezone_offset() {
        let date = parse_rss_date("Wed, 25 Dec 2024 10:00:00 -0800");
        assert!(date.is_some());
        let dt = date.unwrap();
        // -0800 means 10:00 PST = 18:00 UTC
        assert_eq!(dt.hour(), 18);
    }

    #[test]
    fn test_parse_rss_date_boundary_year_end() {
        let date = parse_rss_date("Tue, 31 Dec 2024 23:59:59 +0000");
        assert!(date.is_some());
        let dt = date.unwrap();
        assert_eq!(dt.year(), 2024);
        assert_eq!(dt.month(), 12);
        assert_eq!(dt.day(), 31);
    }

    #[test]
    fn test_parse_rss_date_boundary_year_start() {
        let date = parse_rss_date("Wed, 01 Jan 2025 00:00:00 +0000");
        assert!(date.is_some());
        let dt = date.unwrap();
        assert_eq!(dt.year(), 2025);
        assert_eq!(dt.month(), 1);
        assert_eq!(dt.day(), 1);
    }

    #[test]
    fn test_source_config_clone() {
        let source = SourceConfig {
            name: "Blog".to_string(),
            source_type: SourceType::Rss,
            url: "https://blog.example.com/rss".to_string(),
        };
        let cloned = source.clone();
        assert_eq!(source, cloned);
    }

    #[tokio::test]
    async fn test_fetch_rss_with_mock_server() {
        use wiremock::matchers::{method, path};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;

        // Use current time to ensure freshness check passes
        let now = Utc::now().to_rfc2822();

        let rss_content = format!(
            r#"
            <rss version="2.0">
                <channel>
                    <title>Test Feed</title>
                    <item>
                        <title>Mock Article</title>
                        <link>https://example.com/mock</link>
                        <pubDate>{}</pubDate>
                    </item>
                </channel>
            </rss>
        "#,
            now
        );

        Mock::given(method("GET"))
            .and(path("/feed.xml"))
            .respond_with(ResponseTemplate::new(200).set_body_string(rss_content))
            .mount(&mock_server)
            .await;

        let source = SourceConfig {
            name: "Mock Source".to_string(),
            source_type: SourceType::Rss,
            url: format!("{}/feed.xml", mock_server.uri()),
        };

        let client = create_http_client().unwrap();
        let articles = fetch_from_source(&source, &client, FetchWindow::last_24h())
            .await
            .unwrap();

        assert_eq!(articles.len(), 1);
        assert_eq!(articles[0].title, "Mock Article");
        assert_eq!(articles[0].url, "https://example.com/mock");
    }
}
