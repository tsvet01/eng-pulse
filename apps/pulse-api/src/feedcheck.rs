use pulse_core::SourceKind;
use std::time::Duration;

/// Fetches the URL and checks it parses as RSS or Atom. No LLM here.
pub async fn validate_feed_url(client: &reqwest::Client, url: &str) -> Result<SourceKind, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "invalid URL".to_string())?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err("URL must be http(s)".into());
    }
    let body = client
        .get(parsed)
        .timeout(Duration::from_secs(10))
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("fetch failed: {e}"))?
        .bytes()
        .await
        .map_err(|e| format!("read failed: {e}"))?;
    if rss::Channel::read_from(&body[..]).is_ok() {
        return Ok(SourceKind::Rss);
    }
    if atom_syndication::Feed::read_from(&body[..]).is_ok() {
        return Ok(SourceKind::Atom);
    }
    Err("URL is not an RSS or Atom feed".into())
}

pub fn kind_str(k: SourceKind) -> &'static str {
    match k {
        SourceKind::Rss => "rss",
        SourceKind::Atom => "atom",
        SourceKind::HackerNews => "hackernews",
    }
}
