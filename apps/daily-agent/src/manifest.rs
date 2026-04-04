use serde::{Deserialize, Serialize};

pub(crate) const SUMMARY_SNIPPET_CHARS: usize = 100;

pub(crate) fn gcs_public_url(bucket: &str, object: &str) -> String {
    format!("https://storage.googleapis.com/{}/{}", bucket, object)
}

pub(crate) fn gcs_object_path<'a>(public_url: &'a str, bucket: &str) -> &'a str {
    let prefix = format!("https://storage.googleapis.com/{}/", bucket);
    public_url.strip_prefix(&prefix).unwrap_or(public_url)
}

// --- Manifest Struct ---
#[derive(Serialize, Deserialize, Debug, Clone)]
pub(crate) struct ManifestEntry {
    pub(crate) date: String,
    pub(crate) url: String,
    pub(crate) title: String,
    pub(crate) summary_snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) original_url: Option<String>,
    /// Which model generated the summary
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) model: Option<String>,
    /// Which model selected this article from the candidates
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) selected_by: Option<String>,
    /// Which prompt version generated this summary ("v2" for beta, null for prod)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) prompt_version: Option<String>,
    /// Quality score from LLM judge (0.0-1.0)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) eval_score: Option<f64>,
    /// Article format identifier (e.g. "insight-brief-v3" for V3; null for legacy markdown)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) format: Option<String>,
}

impl ManifestEntry {
    pub(crate) fn summary_id(&self) -> String {
        let provider = self.model.as_deref().unwrap_or("unknown");
        let version = self.prompt_version.as_deref().unwrap_or("v1");
        let suffix = if self.url.contains("-selection.md") { "-selection" } else { "" };
        format!("{}-{}{}", version, provider.split('-').next().unwrap_or(provider), suffix)
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
    fn test_summary_id_v1_gemini() {
        let entry = make_entry("summaries/gemini/2026-03-20.md", Some("gemini-3.1-pro-preview"), None);
        assert_eq!(entry.summary_id(), "v1-gemini");
    }

    #[test]
    fn test_summary_id_v1_claude() {
        let entry = make_entry("summaries/claude/2026-03-20.md", Some("claude-opus-4-6"), None);
        assert_eq!(entry.summary_id(), "v1-claude");
    }

    #[test]
    fn test_summary_id_v2_beta() {
        let entry = make_entry("summaries/beta/claude/2026-03-20.md", Some("claude-opus-4-6"), Some("v2"));
        assert_eq!(entry.summary_id(), "v2-claude");
    }

    #[test]
    fn test_summary_id_v2_selection() {
        let entry = make_entry("summaries/beta/claude/2026-03-20-selection.md", Some("claude-opus-4-6"), Some("v2"));
        assert_eq!(entry.summary_id(), "v2-claude-selection");
    }

    #[test]
    fn test_summary_id_unknown_model() {
        let entry = make_entry("summaries/x/2026-03-20.md", None, None);
        assert_eq!(entry.summary_id(), "v1-unknown");
    }

    #[test]
    fn test_gcs_public_url() {
        assert_eq!(
            gcs_public_url("my-bucket", "path/to/file.md"),
            "https://storage.googleapis.com/my-bucket/path/to/file.md"
        );
    }

    #[test]
    fn test_gcs_object_path_strips_prefix() {
        let url = "https://storage.googleapis.com/my-bucket/summaries/gemini/2026-03-20.md";
        assert_eq!(gcs_object_path(url, "my-bucket"), "summaries/gemini/2026-03-20.md");
    }

    #[test]
    fn test_gcs_object_path_wrong_bucket_returns_full_url() {
        let url = "https://storage.googleapis.com/other-bucket/file.md";
        assert_eq!(gcs_object_path(url, "my-bucket"), url);
    }
}
