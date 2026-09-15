use gcloud_storage::client::Client;
use gcloud_storage::http::objects::upload::{Media, UploadObjectRequest, UploadType};
use llm_client::{call_llm, LlmOptions, LlmProvider};
use tracing::{info, warn};

use crate::manifest::ManifestEntry;

pub(crate) const V3_SCORE_KEYS: &[(&str, f64)] = &[
    ("key_idea_clarity", 0.30),
    ("why_it_matters_relevance", 0.25),
    ("deep_dive_depth", 0.35),
    ("action_quality", 0.10),
];

pub(crate) fn v3_score_total(score: &serde_json::Value) -> f64 {
    let weighted_sum: f64 = V3_SCORE_KEYS
        .iter()
        .map(|&(key, weight)| {
            let val = score.get(key).and_then(|v| v.as_f64()).unwrap_or(3.0);
            val * weight
        })
        .sum();
    weighted_sum / 5.0 // Normalize to 0.0-1.0 (max score per criterion is 5)
}

/// Judge call options: moderate reasoning, with an output cap large enough
/// for the reasoning tokens plus the JSON verdict.
pub(crate) fn judge_options() -> LlmOptions {
    LlmOptions {
        effort: Some("medium".to_string()),
        max_tokens: Some(8000),
        ..Default::default()
    }
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
    let eval_opts = judge_options();
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
                        match gcs_client
                            .upload_object(
                                &UploadObjectRequest {
                                    bucket: bucket_name.to_string(),
                                    ..Default::default()
                                },
                                eval_json,
                                &UploadType::Simple(Media::new(eval_object)),
                            )
                            .await
                        {
                            Ok(_) => info!(prefix = %report_prefix, "Eval report uploaded"),
                            Err(e) => {
                                warn!(prefix = %report_prefix, error = %e, "Failed to upload eval report")
                            }
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

/// Apply eval scores from parsed JSON to manifest entries, matched by summary id.
pub(crate) fn apply_eval_scores(json: &serde_json::Value, entries: &mut [ManifestEntry]) {
    if let Some(scores) = json.get("scores").and_then(|s| s.as_array()) {
        for score in scores {
            if let Some(summary_id) = score.get("summary_id").and_then(|s| s.as_str()) {
                if let Some(entry) = entries.iter_mut().find(|e| e.summary_id() == summary_id) {
                    let total = v3_score_total(score);
                    let reasoning = score
                        .get("reasoning")
                        .and_then(|s| s.as_str())
                        .unwrap_or("")
                        .to_string();
                    info!(summary_id = %summary_id, total = %total, reasoning = %reasoning, "Eval score");
                    entry.eval_score = Some(total);
                }
            }
        }
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
            format: Some("insight-brief-v3".to_string()),
        }
    }

    #[test]
    fn test_apply_eval_scores_matches_by_summary_id() {
        let json = serde_json::json!({
            "scores": [
                {
                    "summary_id": "v3-claude",
                    "key_idea_clarity": 5, "why_it_matters_relevance": 5,
                    "deep_dive_depth": 5, "action_quality": 5,
                    "reasoning": "Good"
                },
                {
                    "summary_id": "v3-shadow",
                    "key_idea_clarity": 1, "why_it_matters_relevance": 1,
                    "deep_dive_depth": 1, "action_quality": 1
                }
            ]
        });
        let mut entries = vec![make_entry(
            "summaries/v3/2026-03-20.json",
            Some("claude-opus-5"),
            Some("v3"),
        )];

        apply_eval_scores(&json, &mut entries);
        assert!((entries[0].eval_score.unwrap() - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_apply_eval_scores_no_match() {
        let json = serde_json::json!({
            "scores": [{"summary_id": "v3-nonexistent", "key_idea_clarity": 5}]
        });
        let mut entries = vec![make_entry(
            "summaries/v3/2026-03-20.json",
            Some("claude-opus-5"),
            Some("v3"),
        )];
        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }

    #[test]
    fn test_judge_options_use_reasoning_effort_and_cap() {
        let opts = judge_options();
        assert_eq!(opts.effort.as_deref(), Some("medium"));
        assert_eq!(opts.max_tokens, Some(8000));
        assert!(opts.model.is_none());
    }

    #[test]
    fn test_v3_score_total_perfect() {
        let score = serde_json::json!({
            "key_idea_clarity": 5,
            "why_it_matters_relevance": 5,
            "deep_dive_depth": 5,
            "action_quality": 5
        });
        let total = v3_score_total(&score);
        assert!((total - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_v3_score_total_defaults_missing() {
        let score = serde_json::json!({
            "key_idea_clarity": 5
        });
        let total = v3_score_total(&score);
        // 5*0.30 + 3*0.25 + 3*0.35 + 3*0.10 = 1.50 + 0.75 + 1.05 + 0.30 = 3.60 / 5 = 0.72
        assert!((total - 0.72).abs() < 0.001);
    }

    #[test]
    fn test_apply_eval_scores_empty_scores_array() {
        let json = serde_json::json!({"scores": []});
        let mut entries = vec![make_entry("x.json", Some("claude"), Some("v3"))];
        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }

    #[test]
    fn test_apply_eval_scores_missing_scores_key() {
        let json = serde_json::json!({"other": "data"});
        let mut entries = vec![make_entry("x.json", Some("claude"), Some("v3"))];
        apply_eval_scores(&json, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }
}
