use serde::{Deserialize, Serialize};
use tracing::{info, warn};
use gcloud_storage::client::Client;
use gcloud_storage::http::objects::upload::{UploadObjectRequest, UploadType, Media};
use llm_client::{call_llm, LlmProvider, LlmOptions};

use crate::manifest::ManifestEntry;
use crate::feedback::{FeedbackEntry, CALIBRATION_AGREEMENT_THRESHOLD};

pub(crate) const SCORE_KEYS: &[&str] = &["clarity", "actionability", "information_density", "faithfulness"];
pub(crate) const EVAL_DEFAULT_SCORE: u64 = 3;
pub(crate) const EVAL_MAX_TOTAL: f64 = 20.0;

pub(crate) fn score_total(score: &serde_json::Value) -> f64 {
    let total: f64 = SCORE_KEYS
        .iter()
        .map(|&key| score.get(key).and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as f64)
        .sum();
    total / EVAL_MAX_TOTAL
}

/// Eval report stored in GCS at eval/{date}.json
/// Currently parsed dynamically via serde_json::Value; typed structs retained for schema documentation.
#[derive(Serialize, Deserialize, Debug, Clone)]
#[allow(dead_code)]
pub(crate) struct EvalReport {
    date: String,
    scores: Vec<EvalEntry>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[allow(dead_code)]
pub(crate) struct EvalEntry {
    /// Composite key: "{prompt_version}-{provider}", e.g. "v1-gemini"
    summary_id: String,
    prompt_version: String,
    model: String,
    title: String,
    scores: EvalCriteria,
    /// Normalized 0.0-1.0 (sum of 4 scores / 20)
    total: f64,
    judge_reasoning: String,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
#[allow(dead_code)]
pub(crate) struct EvalCriteria {
    clarity: u8,
    actionability: u8,
    information_density: u8,
    faithfulness: u8,
}

/// Run a single eval pass: send prompt to LLM, parse JSON response, upload report.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn run_eval_pass(
    http_client: &reqwest::Client,
    provider: LlmProvider,
    api_key: &str,
    prompt: String,
    gcs_client: &Client,
    bucket_name: &str,
    today: &str,
    report_prefix: &str,
) -> Option<serde_json::Value> {
    let eval_opts = LlmOptions { temperature: Some(0.3), ..Default::default() };
    match call_llm(http_client, provider, api_key, prompt, &eval_opts).await {
        Ok(eval_response) => {
            let cleaned = eval_response
                .trim()
                .trim_start_matches("```json")
                .trim_start_matches("```")
                .trim_end_matches("```")
                .trim();

            match serde_json::from_str::<serde_json::Value>(cleaned) {
                Ok(json) => {
                    // Upload eval report
                    let eval_object = format!("{}/{}.json", report_prefix, today);
                    if let Ok(eval_json) = serde_json::to_vec_pretty(&json) {
                        match gcs_client.upload_object(
                            &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                            eval_json,
                            &UploadType::Simple(Media::new(eval_object)),
                        ).await {
                            Ok(_) => info!(prefix = %report_prefix, "Eval report uploaded"),
                            Err(e) => warn!(prefix = %report_prefix, error = %e, "Failed to upload eval report"),
                        }
                    }
                    Some(json)
                }
                Err(e) => {
                    warn!(prefix = %report_prefix, error = %e, "Failed to parse eval response as JSON");
                    None
                }
            }
        }
        Err(e) => {
            warn!(prefix = %report_prefix, error = %e, "Eval pass failed");
            None
        }
    }
}

/// Apply eval scores from parsed JSON to manifest entries.
pub(crate) fn apply_eval_scores(json: &serde_json::Value, entries: &mut [ManifestEntry]) {
    if let Some(scores) = json.get("scores").and_then(|s| s.as_array()) {
        for score in scores {
            let summary_id = score.get("summary_id").and_then(|s| s.as_str()).unwrap_or("");
            let total = score_total(score);
            let reasoning = score.get("reasoning").and_then(|s| s.as_str()).unwrap_or("").to_string();

            info!(summary_id = %summary_id, total = %total, reasoning = %reasoning, "Eval score");

            for entry in entries.iter_mut() {
                if entry.summary_id() == summary_id {
                    entry.eval_score = Some(total);
                }
            }
        }
    }
}

/// Log agreement rate between user feedback and calibrated eval scores.
pub(crate) fn log_calibration_agreement(
    feedback: &[FeedbackEntry],
    calibrated_json: &serde_json::Value,
    entries: &[ManifestEntry],
) {
    let scores_map: std::collections::HashMap<String, f64> = calibrated_json
        .get("scores")
        .and_then(|s| s.as_array())
        .map(|scores| {
            scores.iter().filter_map(|s| {
                let id = s.get("summary_id")?.as_str()?;
                Some((id.to_string(), score_total(s)))
            }).collect()
        })
        .unwrap_or_default();

    let mut agreements = 0u32;
    let mut total_checked = 0u32;

    for fb in feedback {
        // Find the manifest entry matching this feedback URL
        if let Some(entry) = entries.iter().find(|e| e.url == fb.summary_url) {
            if let Some(&score) = scores_map.get(&entry.summary_id()) {
                total_checked += 1;
                let score_is_up = score > CALIBRATION_AGREEMENT_THRESHOLD;
                let feedback_is_up = fb.effective_feedback() == Some("up");
                if score_is_up == feedback_is_up {
                    agreements += 1;
                }
            }
        }
    }

    if total_checked > 0 {
        let agreement_rate = agreements as f64 / total_checked as f64;
        info!(
            agreements = agreements,
            total = total_checked,
            rate = format!("{:.1}%", agreement_rate * 100.0),
            "Calibration agreement with user feedback"
        );
    } else {
        info!("No overlapping entries between feedback and calibrated eval");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_entry(url: &str, model: Option<&str>, prompt_version: Option<&str>) -> ManifestEntry {
        ManifestEntry {
            date: "2026-03-20".to_string(),
            url: url.to_string(),
            title: "Test".to_string(),
            summary_snippet: "...".to_string(),
            original_url: None,
            model: model.map(|s| s.to_string()),
            selected_by: None,
            prompt_version: prompt_version.map(|s| s.to_string()),
            eval_score: None,
            format: None,
        }
    }

    #[test]
    fn test_score_total_all_present() {
        let score = serde_json::json!({
            "clarity": 5, "actionability": 4, "information_density": 3, "faithfulness": 5
        });
        let total = score_total(&score);
        assert!((total - 0.85).abs() < 0.001); // (5+4+3+5)/20 = 0.85
    }

    #[test]
    fn test_score_total_missing_keys_default_to_3() {
        let score = serde_json::json!({"clarity": 5});
        let total = score_total(&score);
        // (5 + 3 + 3 + 3) / 20 = 0.70
        assert!((total - 0.70).abs() < 0.001);
    }

    #[test]
    fn test_score_total_all_missing() {
        let score = serde_json::json!({});
        let total = score_total(&score);
        // (3 + 3 + 3 + 3) / 20 = 0.60
        assert!((total - 0.60).abs() < 0.001);
    }

    #[test]
    fn test_score_total_perfect() {
        let score = serde_json::json!({
            "clarity": 5, "actionability": 5, "information_density": 5, "faithfulness": 5
        });
        assert!((score_total(&score) - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_score_total_minimum() {
        let score = serde_json::json!({
            "clarity": 1, "actionability": 1, "information_density": 1, "faithfulness": 1
        });
        assert!((score_total(&score) - 0.20).abs() < 0.001);
    }

    #[test]
    fn test_apply_eval_scores_matches_by_summary_id() {
        let json = serde_json::json!({
            "scores": [{
                "summary_id": "v1-gemini",
                "clarity": 5, "actionability": 4, "information_density": 3, "faithfulness": 5,
                "reasoning": "Good"
            }]
        });
        let mut entries = vec![
            make_entry("summaries/gemini/2026-03-20.md", Some("gemini-3.1-pro-preview"), None),
            make_entry("summaries/claude/2026-03-20.md", Some("claude-opus-4-6"), None),
        ];

        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_some());
        assert!((entries[0].eval_score.unwrap() - 0.85).abs() < 0.001);
        assert!(entries[1].eval_score.is_none()); // claude entry should not be affected
    }

    #[test]
    fn test_apply_eval_scores_no_match() {
        let json = serde_json::json!({
            "scores": [{"summary_id": "v1-nonexistent", "clarity": 5, "actionability": 5, "information_density": 5, "faithfulness": 5}]
        });
        let mut entries = vec![make_entry("summaries/gemini/2026-03-20.md", Some("gemini-3.1-pro-preview"), None)];
        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }

    #[test]
    fn test_apply_eval_scores_empty_scores_array() {
        let json = serde_json::json!({"scores": []});
        let mut entries = vec![make_entry("x.md", Some("gemini"), None)];
        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }

    #[test]
    fn test_apply_eval_scores_missing_scores_key() {
        let json = serde_json::json!({"other": "data"});
        let mut entries = vec![make_entry("x.md", Some("gemini"), None)];
        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }
}
