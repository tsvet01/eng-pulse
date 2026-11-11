use gcloud_storage::client::Client;
use gcloud_storage::http::objects::upload::{Media, UploadObjectRequest, UploadType};
use llm_client::{call_llm_typed, LlmOptions, LlmProvider};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::manifest::ManifestEntry;

/// Judge reply: one row per summary, plus the head-to-head winner when two are judged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct JudgeVerdict {
    pub(crate) scores: Vec<JudgeScore>,
    /// summary_id of the preferred summary, "tie", or null when only one summary was judged.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) pairwise_winner: Option<String>,
}

/// Scores on a 1-5 scale for one summary.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub(crate) struct JudgeScore {
    pub(crate) summary_id: String,
    pub(crate) key_idea_clarity: u8,
    pub(crate) why_it_matters_relevance: u8,
    pub(crate) deep_dive_depth: u8,
    pub(crate) action_quality: u8,
    pub(crate) reasoning: String,
}

/// Weighted total normalized to 0.0-1.0 (max score per criterion is 5).
pub(crate) fn v3_score_total(score: &JudgeScore) -> f64 {
    let weighted_sum = f64::from(score.key_idea_clarity) * 0.30
        + f64::from(score.why_it_matters_relevance) * 0.25
        + f64::from(score.deep_dive_depth) * 0.35
        + f64::from(score.action_quality) * 0.10;
    weighted_sum / 5.0
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

/// Run a single eval pass: schema-constrained judge call, then upload the report.
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
) -> Option<JudgeVerdict> {
    let eval_opts = judge_options();
    let verdict =
        match call_llm_typed::<JudgeVerdict>(http_client, provider, api_key, prompt, &eval_opts)
            .await
        {
            Ok(typed) => typed.value,
            Err(e) => {
                warn!(prefix = %report_prefix, error = %e, "Eval pass failed");
                return None;
            }
        };

    let eval_object = format!("{}/{}.json", report_prefix, today);
    if let Ok(eval_json) = serde_json::to_vec_pretty(&verdict) {
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
    Some(verdict)
}

/// Apply judge scores to manifest entries, matched by summary id.
pub(crate) fn apply_eval_scores(verdict: &JudgeVerdict, entries: &mut [ManifestEntry]) {
    for score in &verdict.scores {
        if let Some(entry) = entries
            .iter_mut()
            .find(|e| e.summary_id() == score.summary_id)
        {
            let total = v3_score_total(score);
            info!(summary_id = %score.summary_id, total = %total, reasoning = %score.reasoning, "Eval score");
            entry.eval_score = Some(total);
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

    fn score(summary_id: &str, value: u8) -> JudgeScore {
        JudgeScore {
            summary_id: summary_id.to_string(),
            key_idea_clarity: value,
            why_it_matters_relevance: value,
            deep_dive_depth: value,
            action_quality: value,
            reasoning: "Good".to_string(),
        }
    }

    #[test]
    fn test_apply_eval_scores_matches_by_summary_id() {
        let verdict = JudgeVerdict {
            scores: vec![score("v3-claude", 5), score("v3-shadow", 1)],
            pairwise_winner: Some("v3-claude".to_string()),
        };
        let mut entries = vec![make_entry(
            "summaries/v3/2026-03-20.json",
            Some("claude-opus-5-5"),
            Some("v3"),
        )];

        apply_eval_scores(&verdict, &mut entries);
        assert!((entries[0].eval_score.unwrap() - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_apply_eval_scores_no_match() {
        let verdict = JudgeVerdict {
            scores: vec![score("v3-nonexistent", 5)],
            pairwise_winner: None,
        };
        let mut entries = vec![make_entry(
            "summaries/v3/2026-03-20.json",
            Some("claude-opus-5-5"),
            Some("v3"),
        )];
        apply_eval_scores(&verdict, &mut entries);
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
        assert!((v3_score_total(&score("x", 5)) - 1.0).abs() < 0.001);
    }

    #[test]
    fn test_v3_score_total_weights() {
        let mut s = score("x", 3);
        s.key_idea_clarity = 5;
        // 5*0.30 + 3*0.25 + 3*0.35 + 3*0.10 = 3.60 / 5 = 0.72
        assert!((v3_score_total(&s) - 0.72).abs() < 0.001);
    }

    #[test]
    fn test_judge_verdict_report_shape_matches_previous_reports() {
        // Readers of eval-v3/{date}.json expect this shape; the winner is absent
        // when only one summary was judged.
        let verdict = JudgeVerdict {
            scores: vec![score("v3-claude", 4)],
            pairwise_winner: None,
        };
        let json = serde_json::to_value(&verdict).unwrap();
        assert_eq!(json["scores"][0]["summary_id"], "v3-claude");
        assert_eq!(json["scores"][0]["deep_dive_depth"], 4);
        assert_eq!(json["scores"][0]["reasoning"], "Good");
        assert!(json.get("pairwise_winner").is_none());

        let legacy = r#"{"scores":[{"summary_id":"v3-claude","key_idea_clarity":5,"why_it_matters_relevance":5,"deep_dive_depth":5,"action_quality":5,"reasoning":"r"}]}"#;
        let parsed: JudgeVerdict = serde_json::from_str(legacy).unwrap();
        assert_eq!(parsed.pairwise_winner, None);
    }

    #[test]
    fn test_judge_verdict_schema_lists_all_fields_as_required() {
        let schema = llm_client::strict_schema(
            serde_json::to_value(schemars::schema_for!(JudgeVerdict)).unwrap(),
        );
        let mut required: Vec<&str> = schema["required"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        required.sort_unstable();
        assert_eq!(required, ["pairwise_winner", "scores"]);
        let row = &schema["$defs"]["JudgeScore"];
        assert_eq!(row["additionalProperties"], false);
        assert_eq!(row["properties"]["key_idea_clarity"]["type"], "integer");
    }

    #[test]
    fn test_apply_eval_scores_empty_scores() {
        let verdict = JudgeVerdict {
            scores: vec![],
            pairwise_winner: None,
        };
        let mut entries = vec![make_entry("x.json", Some("claude"), Some("v3"))];
        apply_eval_scores(&verdict, &mut entries);
        assert!(entries[0].eval_score.is_none());
    }
}
