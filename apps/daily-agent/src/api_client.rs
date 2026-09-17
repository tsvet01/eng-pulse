//! Dual-write client for pulse-api: the day's brief goes to the API as well as
//! GCS. Enabled only when both `PULSE_API_URL` and `PIPELINE_SERVICE_TOKEN` are
//! set, so an unconfigured run keeps its previous behavior.

use pulse_core::{Brief, Feed, InsightBrief};
use std::time::Duration;

const API_TIMEOUT_SECS: u64 = 20;

pub struct PulseApi {
    base: String,
    token: String,
    http: reqwest::Client,
}

impl PulseApi {
    pub fn new(base: String, token: String) -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(API_TIMEOUT_SECS))
            .build()
            .expect("client");
        Self {
            base: base.trim_end_matches('/').to_string(),
            token,
            http,
        }
    }

    /// Both values are required; an empty value counts as missing.
    pub fn from_pair(url: Option<String>, token: Option<String>) -> Option<Self> {
        match (url, token) {
            (Some(u), Some(t)) if !u.is_empty() && !t.is_empty() => Some(Self::new(u, t)),
            _ => None,
        }
    }

    pub fn from_env() -> Option<Self> {
        Self::from_pair(
            std::env::var("PULSE_API_URL").ok(),
            std::env::var("PIPELINE_SERVICE_TOKEN").ok(),
        )
    }

    pub async fn post_brief(&self, brief: &Brief) -> Result<(), String> {
        let resp = self
            .http
            .post(format!("{}/internal/briefs", self.base))
            .bearer_auth(&self.token)
            .json(brief)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = resp.status();
        if status.is_success() {
            Ok(())
        } else {
            Err(format!(
                "pulse-api returned {status}: {}",
                resp.text().await.unwrap_or_default()
            ))
        }
    }

    /// Feed count from `/internal/feeds`; exercises the service token too.
    pub async fn internal_feeds(&self) -> Result<usize, String> {
        let resp = self
            .http
            .get(format!("{}/internal/feeds", self.base))
            .bearer_auth(&self.token)
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("internal/feeds {status}"));
        }
        let feeds: Vec<Feed> = resp.json().await.map_err(|e| e.to_string())?;
        Ok(feeds.len())
    }

    pub async fn healthz(&self) -> Result<(), String> {
        let resp = self
            .http
            .get(format!("{}/healthz", self.base))
            .send()
            .await
            .map_err(|e| e.to_string())?;
        if resp.status().is_success() {
            Ok(())
        } else {
            Err(format!("healthz {}", resp.status()))
        }
    }
}

/// Wrap the brief JSON the pipeline already uploaded in the API's envelope.
pub fn brief_for_api(
    date: &str,
    brief_json: &str,
    article_url: &str,
    article_title: &str,
    model: Option<&str>,
    eval_score: Option<f64>,
) -> Result<Brief, String> {
    let payload: InsightBrief =
        serde_json::from_str(brief_json).map_err(|e| format!("brief json: {e}"))?;
    Ok(Brief {
        feed_slug: "engineering".into(),
        date: date.into(),
        format: "insight-brief-v3".into(),
        payload,
        article_url: article_url.into(),
        article_title: article_title.into(),
        model: model.map(String::from),
        eval_score,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::{
        matchers::{bearer_token, body_partial_json, method, path},
        Mock, MockServer, ResponseTemplate,
    };

    const V3: &str = r#"{"key_idea":"k","why_it_matters":"w","what_to_change":null,"deep_dive":"d","meta":{"confidence":0.9,"category":"c"}}"#;

    #[tokio::test]
    async fn posts_brief_with_service_token() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/internal/briefs"))
            .and(bearer_token("tok"))
            .and(body_partial_json(serde_json::json!({
                "feed_slug": "engineering",
                "date": "2026-09-16",
                "article_title": "T"
            })))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({"created": true})),
            )
            .expect(1)
            .mount(&server)
            .await;
        let api = PulseApi::new(server.uri(), "tok".into());
        let b = brief_for_api(
            "2026-09-16",
            V3,
            "https://x",
            "T",
            Some("claude-opus-5"),
            Some(0.9),
        )
        .unwrap();
        api.post_brief(&b).await.unwrap();
    }

    #[tokio::test]
    async fn server_error_is_reported_not_panicked() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;
        let api = PulseApi::new(server.uri(), "tok".into());
        let b = brief_for_api("2026-09-16", V3, "https://x", "T", None, None).unwrap();
        assert!(api.post_brief(&b).await.unwrap_err().contains("500"));
    }

    #[tokio::test]
    async fn internal_feeds_counts_with_service_token() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/internal/feeds"))
            .and(bearer_token("tok"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"slug":"engineering","name":"Engineering","description":null,"topics":[],"sources":[],"is_active":true}
            ])))
            .expect(1)
            .mount(&server)
            .await;
        let api = PulseApi::new(server.uri(), "tok".into());
        assert_eq!(api.internal_feeds().await.unwrap(), 1);
    }

    #[tokio::test]
    async fn internal_feeds_rejected_token_is_reported() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;
        let api = PulseApi::new(server.uri(), "bad".into());
        assert!(api.internal_feeds().await.unwrap_err().contains("401"));
    }

    #[test]
    fn from_env_requires_both_vars() {
        assert!(PulseApi::from_pair(None, Some("t".into())).is_none());
        assert!(PulseApi::from_pair(Some("https://api".into()), Some("t".into())).is_some());
    }

    #[test]
    fn invalid_payload_is_error() {
        assert!(brief_for_api("2026-09-16", "{not json", "u", "t", None, None).is_err());
    }
}
