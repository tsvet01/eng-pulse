use chrono::Utc;
use gcloud_storage::client::Client;
use gcloud_storage::http::objects::download::Range;
use gcloud_storage::http::objects::get::GetObjectRequest;
use serde::Deserialize;
use tracing::{info, warn};

use crate::manifest::ManifestEntry;

/// Stop scanning back through feedback files once this many entries are loaded.
pub(crate) const FEEDBACK_MIN_ENTRIES: usize = 5;
pub(crate) const FEEDBACK_LOOKBACK_DAYS: i64 = 30;

/// The fields of a feedback record the selector uses; other fields are ignored.
#[derive(Deserialize, Debug, Clone)]
pub(crate) struct FeedbackEntry {
    pub(crate) summary_url: String,
    #[serde(default)]
    pub(crate) selection_feedback: Option<String>,
}

/// Load recent user feedback from GCS, scanning backwards up to FEEDBACK_LOOKBACK_DAYS.
pub(crate) async fn load_recent_feedback(
    gcs_client: &Client,
    bucket_name: &str,
) -> Vec<FeedbackEntry> {
    let mut all_feedback = Vec::new();
    let now = Utc::now();

    for days_ago in 0..FEEDBACK_LOOKBACK_DAYS {
        let date = (now - chrono::Duration::days(days_ago))
            .format("%Y-%m-%d")
            .to_string();
        let object = format!("feedback/{}.json", date);

        match gcs_client
            .download_object(
                &GetObjectRequest {
                    bucket: bucket_name.to_string(),
                    object,
                    ..Default::default()
                },
                &Range::default(),
            )
            .await
        {
            Ok(data) => match serde_json::from_slice::<Vec<FeedbackEntry>>(&data) {
                Ok(mut entries) => all_feedback.append(&mut entries),
                Err(e) => warn!(date = %date, error = %e, "Failed to parse feedback JSON"),
            },
            Err(_) => {
                // No feedback file for this date — expected for most days
            }
        }
        if all_feedback.len() >= FEEDBACK_MIN_ENTRIES {
            break;
        }
    }

    info!(count = all_feedback.len(), "Loaded recent feedback entries");
    all_feedback
}

/// Build a selection context string from recent feedback for the article selector.
pub(crate) fn build_selection_context(
    feedback: &[FeedbackEntry],
    manifest: &[ManifestEntry],
) -> Option<String> {
    let with_selection: Vec<&FeedbackEntry> = feedback
        .iter()
        .filter(|f| f.selection_feedback.is_some())
        .collect();

    if with_selection.is_empty() {
        return None;
    }

    let mut context = String::from("Recent reader feedback on past selections:\n");

    for entry in with_selection.iter().take(6) {
        let title = manifest
            .iter()
            .find(|m| m.url == entry.summary_url)
            .map(|m| m.title.as_str())
            .unwrap_or("Unknown");
        let signal = match entry.selection_feedback.as_deref() {
            Some("up") => "Liked",
            Some("down") => "Disliked",
            _ => continue,
        };
        context.push_str(&format!("- {}: \"{}\"\n", signal, title));
    }

    context.push_str("Use this signal to better match today's pick to the reader's taste.\n");
    Some(context)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_selection_context_with_feedback() {
        let feedback = vec![FeedbackEntry {
            summary_url: "https://example.com/a".to_string(),
            selection_feedback: Some("up".to_string()),
        }];
        let manifest = vec![ManifestEntry {
            date: "2026-04-01".to_string(),
            url: "https://example.com/a".to_string(),
            title: "Great Article".to_string(),
            summary_snippet: "...".to_string(),
            original_url: None,
            model: None,
            selected_by: None,
            prompt_version: None,
            eval_score: None,
            format: None,
        }];
        let ctx = build_selection_context(&feedback, &manifest);
        assert!(ctx.is_some());
        assert!(ctx.unwrap().contains("Liked: \"Great Article\""));
    }

    #[test]
    fn test_feedback_entry_ignores_unused_fields() {
        let json = r#"[{"summary_url": "https://example.com/a", "feedback": "up",
            "selection_feedback": "down", "summary_feedback": null,
            "prompt_version": "v3", "uid": "u1", "timestamp": "2026-04-01T00:00:00Z"}]"#;
        let entries: Vec<FeedbackEntry> = serde_json::from_str(json).unwrap();
        assert_eq!(entries[0].selection_feedback.as_deref(), Some("down"));
    }

    #[test]
    fn test_build_selection_context_empty() {
        let ctx = build_selection_context(&[], &[]);
        assert!(ctx.is_none());
    }
}
