//! Shared JSON contract types for the Eng Pulse pipeline and API.
//!
//! These types mirror the JSON that the daily-agent already uploads to
//! `summaries/v3/{date}.json` and friends. Phase 1's API and the mobile
//! clients decode the same shape; `fixtures()` below is the single source
//! of truth for what that shape looks like, written out as
//! `docs/contracts/*.json` by the `fixtures` binary so drift shows up in CI.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Feed {
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub topics: Vec<String>,
    pub sources: Vec<FeedSource>,
    pub is_active: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeedSource {
    pub url: String,
    pub kind: SourceKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    Rss,
    Atom,
    #[serde(rename = "hackernews")]
    HackerNews,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InsightBrief {
    pub key_idea: String,
    pub why_it_matters: String,
    pub what_to_change: Option<String>,
    pub deep_dive: String,
    pub meta: Option<BriefMeta>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BriefMeta {
    pub confidence: Option<f64>,
    pub category: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Brief {
    pub feed_slug: String,
    /// YYYY-MM-DD
    pub date: String,
    /// "insight-brief-v3"
    pub format: String,
    pub payload: InsightBrief,
    pub article_url: String,
    pub article_title: String,
    pub model: Option<String>,
    pub eval_score: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RunReport {
    pub date: String,
    pub feeds: Vec<FeedRun>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeedRun {
    pub feed_slug: String,
    pub status: RunStatus,
    pub article_url: Option<String>,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub est_cost_usd: f64,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RunStatus {
    Ok,
    Skipped,
    Failed,
}

/// Deterministic samples of every contract type; mobile tests decode these.
pub fn fixtures() -> Vec<(&'static str, serde_json::Value)> {
    let feed = Feed {
        slug: "engineering".into(),
        name: "Engineering".into(),
        description: Some("Systems, infrastructure, AI tooling".into()),
        topics: vec!["distributed systems".into(), "rust".into()],
        sources: vec![FeedSource {
            url: "https://blog.cloudflare.com/rss/".into(),
            kind: SourceKind::Rss,
        }],
        is_active: true,
    };
    let brief = Brief {
        feed_slug: "engineering".into(),
        date: "2026-09-01".into(),
        format: "insight-brief-v3".into(),
        payload: InsightBrief {
            key_idea: "One clear sentence.".into(),
            why_it_matters: "Why the reader cares.".into(),
            what_to_change: Some("One concrete action.".into()),
            deep_dive: "## Deep dive\n\nMarkdown body.".into(),
            meta: Some(BriefMeta {
                confidence: Some(0.9),
                category: Some("platform-engineering".into()),
            }),
        },
        article_url: "https://example.com/post".into(),
        article_title: "Example post".into(),
        model: Some("claude-opus-4-8".into()),
        eval_score: Some(0.95),
    };
    let run = RunReport {
        date: "2026-09-01".into(),
        feeds: vec![FeedRun {
            feed_slug: "engineering".into(),
            status: RunStatus::Ok,
            article_url: Some("https://example.com/post".into()),
            input_tokens: 2845,
            output_tokens: 1410,
            est_cost_usd: 0.049,
            error: None,
        }],
    };
    vec![
        ("feed", serde_json::to_value(feed).unwrap()),
        ("brief", serde_json::to_value(brief).unwrap()),
        ("run_report", serde_json::to_value(run).unwrap()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insight_brief_decodes_production_shape() {
        // Exact shape the daily-agent uploads to summaries/v3/{date}.json today.
        let json = r#"{"key_idea":"k","why_it_matters":"w","what_to_change":null,"deep_dive":"d","meta":{"confidence":0.9,"category":"platform-engineering"}}"#;
        let b: InsightBrief = serde_json::from_str(json).unwrap();
        assert_eq!(b.key_idea, "k");
        assert!(b.what_to_change.is_none());
        assert_eq!(
            b.meta.unwrap().category.as_deref(),
            Some("platform-engineering")
        );
    }

    #[test]
    fn source_kind_serializes_like_sources_json() {
        assert_eq!(
            serde_json::to_string(&SourceKind::HackerNews).unwrap(),
            "\"hackernews\""
        );
        assert_eq!(serde_json::to_string(&SourceKind::Rss).unwrap(), "\"rss\"");
    }

    #[test]
    fn fixtures_are_deterministic_and_round_trip() {
        let a = fixtures();
        let b = fixtures();
        assert_eq!(a, b);
        for (name, value) in a {
            match name {
                "feed" => {
                    let _: Feed = serde_json::from_value(value).unwrap();
                }
                "brief" => {
                    let _: Brief = serde_json::from_value(value).unwrap();
                }
                "run_report" => {
                    let _: RunReport = serde_json::from_value(value).unwrap();
                }
                other => panic!("unexpected fixture {other}"),
            }
        }
    }
}
