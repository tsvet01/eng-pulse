use serde::Deserialize;
use chrono::Utc;
use tracing::{info, warn};
use gcloud_storage::client::Client;
use gcloud_storage::http::objects::download::Range;
use gcloud_storage::http::objects::get::GetObjectRequest;

use crate::manifest::{ManifestEntry, gcs_object_path};

pub(crate) const CALIBRATION_MIN_RATINGS: usize = 5;
pub(crate) const CALIBRATION_LOOKBACK_DAYS: i64 = 30;
pub(crate) const CALIBRATION_EXCERPT_WORDS: usize = 200;
pub(crate) const CALIBRATION_AGREEMENT_THRESHOLD: f64 = 0.6;

#[derive(Deserialize, Debug, Clone)]
#[allow(dead_code)]
pub(crate) struct FeedbackEntry {
    pub(crate) summary_url: String,
    #[serde(default)]
    pub(crate) feedback: Option<String>,
    #[serde(default)]
    pub(crate) selection_feedback: Option<String>,
    #[serde(default)]
    pub(crate) summary_feedback: Option<String>,
    #[serde(default)]
    pub(crate) prompt_version: Option<String>,
    pub(crate) uid: String,
    pub(crate) timestamp: String,
}

impl FeedbackEntry {
    /// Effective feedback signal: legacy field, then selection (stronger), then summary as last resort.
    pub(crate) fn effective_feedback(&self) -> Option<&str> {
        self.feedback.as_deref()
            .or(self.selection_feedback.as_deref())
            .or(self.summary_feedback.as_deref())
    }
}

/// Load recent user feedback from GCS, scanning backwards up to CALIBRATION_LOOKBACK_DAYS.
pub(crate) async fn load_recent_feedback(gcs_client: &Client, bucket_name: &str) -> Vec<FeedbackEntry> {
    let mut all_feedback = Vec::new();
    let now = Utc::now();

    for days_ago in 0..CALIBRATION_LOOKBACK_DAYS {
        let date = (now - chrono::Duration::days(days_ago)).format("%Y-%m-%d").to_string();
        let object = format!("feedback/{}.json", date);

        match gcs_client.download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object,
                ..Default::default()
            },
            &Range::default(),
        ).await {
            Ok(data) => {
                match serde_json::from_slice::<Vec<FeedbackEntry>>(&data) {
                    Ok(mut entries) => all_feedback.append(&mut entries),
                    Err(e) => warn!(date = %date, error = %e, "Failed to parse feedback JSON"),
                }
            }
            Err(_) => {
                // No feedback file for this date — expected for most days
            }
        }
        if all_feedback.len() >= CALIBRATION_MIN_RATINGS {
            break;
        }
    }

    info!(count = all_feedback.len(), "Loaded recent feedback entries");
    all_feedback
}

/// Check that feedback contains at least one "up" and one "down" vote.
pub(crate) fn has_both_polarities(feedback: &[FeedbackEntry]) -> bool {
    let has_up = feedback.iter().any(|f| f.effective_feedback() == Some("up"));
    let has_down = feedback.iter().any(|f| f.effective_feedback() == Some("down"));
    has_up && has_down
}

/// Truncate content to approximately max_words words.
pub(crate) fn excerpt(content: &str, max_words: usize) -> String {
    let words: Vec<&str> = content.split_whitespace().collect();
    if words.len() <= max_words {
        words.join(" ")
    } else {
        format!("{}...", words[..max_words].join(" "))
    }
}

/// Download summary excerpts for a set of feedback entries.
pub(crate) async fn download_feedback_excerpts(
    entries: &[&FeedbackEntry],
    gcs_client: &Client,
    bucket_name: &str,
    manifest: &[ManifestEntry],
) -> Vec<String> {
    let mut results = Vec::new();
    for entry in entries {
        let gcs_path = gcs_object_path(&entry.summary_url, bucket_name);
        let title = manifest.iter()
            .find(|m| m.url == entry.summary_url)
            .map(|m| m.title.clone())
            .unwrap_or_else(|| "Unknown".to_string());

        match gcs_client.download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object: gcs_path.to_string(),
                ..Default::default()
            },
            &Range::default(),
        ).await {
            Ok(data) => {
                if let Ok(content) = String::from_utf8(data) {
                    results.push(format!(
                        "[Title: \"{}\"]\n{}",
                        title,
                        excerpt(&content, CALIBRATION_EXCERPT_WORDS)
                    ));
                }
            }
            Err(e) => warn!(url = %entry.summary_url, error = %e, "Failed to download feedback summary"),
        }
    }
    results
}

/// Build a calibration context string from user feedback for the eval judge.
pub(crate) async fn build_calibration_context(
    feedback: &[FeedbackEntry],
    gcs_client: &Client,
    bucket_name: &str,
    manifest: &[ManifestEntry],
) -> Option<String> {
    let both_polarities = has_both_polarities(feedback);
    if feedback.len() < CALIBRATION_MIN_RATINGS || !both_polarities {
        info!(
            count = feedback.len(),
            has_polarities = both_polarities,
            "Insufficient feedback for calibration"
        );
        return None;
    }

    // Take up to 2 most recent "up" and 2 most recent "down" entries
    let ups: Vec<&FeedbackEntry> = feedback.iter().filter(|f| f.effective_feedback() == Some("up")).take(2).collect();
    let downs: Vec<&FeedbackEntry> = feedback.iter().filter(|f| f.effective_feedback() == Some("down")).take(2).collect();

    let (highly_rated, poorly_rated) = tokio::join!(
        download_feedback_excerpts(&ups, gcs_client, bucket_name, manifest),
        download_feedback_excerpts(&downs, gcs_client, bucket_name, manifest),
    );

    if highly_rated.is_empty() && poorly_rated.is_empty() {
        warn!("Could not download any feedback summaries for calibration");
        return None;
    }

    let mut context = String::from("## User Calibration\n\n");

    if !highly_rated.is_empty() {
        context.push_str("The user rated these summaries highly:\n\n");
        for entry in &highly_rated {
            context.push_str(entry);
            context.push_str("\n\n");
        }
    }

    if !poorly_rated.is_empty() {
        context.push_str("The user rated these summaries poorly:\n\n");
        for entry in &poorly_rated {
            context.push_str(entry);
            context.push_str("\n\n");
        }
    }

    context.push_str("Use these as reference points when scoring. Align your quality assessment with the user's demonstrated preferences.\n");

    info!("Built calibration context with {} highly and {} poorly rated examples", highly_rated.len(), poorly_rated.len());
    Some(context)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_has_both_polarities_true() {
        let feedback = vec![
            FeedbackEntry {
                summary_url: "https://example.com/a".to_string(),
                feedback: Some("up".to_string()),
                selection_feedback: None,
                summary_feedback: None,
                prompt_version: None,
                uid: "u1".to_string(),
                timestamp: "2026-03-15T00:00:00Z".to_string(),
            },
            FeedbackEntry {
                summary_url: "https://example.com/b".to_string(),
                feedback: Some("down".to_string()),
                selection_feedback: None,
                summary_feedback: None,
                prompt_version: None,
                uid: "u1".to_string(),
                timestamp: "2026-03-15T00:00:00Z".to_string(),
            },
        ];
        assert!(has_both_polarities(&feedback));
    }

    #[test]
    fn test_has_both_polarities_all_up() {
        let feedback = vec![
            FeedbackEntry {
                summary_url: "https://example.com/a".to_string(),
                feedback: Some("up".to_string()),
                selection_feedback: None,
                summary_feedback: None,
                prompt_version: None,
                uid: "u1".to_string(),
                timestamp: "2026-03-15T00:00:00Z".to_string(),
            },
            FeedbackEntry {
                summary_url: "https://example.com/b".to_string(),
                feedback: Some("up".to_string()),
                selection_feedback: None,
                summary_feedback: None,
                prompt_version: None,
                uid: "u1".to_string(),
                timestamp: "2026-03-15T00:00:00Z".to_string(),
            },
        ];
        assert!(!has_both_polarities(&feedback));
    }

    #[test]
    fn test_excerpt_truncation() {
        let content = "one two three four five six seven eight nine ten";
        let result = excerpt(content, 5);
        assert_eq!(result, "one two three four five...");
    }

    #[test]
    fn test_excerpt_short_content() {
        let content = "hello world";
        let result = excerpt(content, 200);
        assert_eq!(result, "hello world");
    }
}
