//! Production prompts for the daily run: two-phase article selection and the
//! V3 Insight Brief. Prompt wording is a tuned artifact; change only on request.

/// Prompt version tag written to the manifest for the Insight Brief.
pub const PROMPT_VERSION: &str = "v3";

/// Prepend optional context blocks to a base prompt.
fn inject_context(
    base: String,
    selection_context: Option<&str>,
    recent_picks: Option<&str>,
) -> String {
    let mut prompt = base;
    if let Some(ctx) = selection_context {
        prompt = format!("{}\n\n{}", ctx, prompt);
    }
    if let Some(picks) = recent_picks {
        prompt = format!("{}\n\n{}", picks, prompt);
    }
    prompt
}

/// Headline-only single pick; fallback when the shortlist cannot be parsed.
pub fn selection_prompt(articles_text: &str) -> String {
    format!(
        "You are an expert Software Engineering Editor. Review the following list of article headlines collected today. Select the SINGLE most valuable, educational, and impactful article for a senior software engineer to read. Consider technical depth, novelty, and broad relevance.\n\n{}\n\nReply ONLY with the integer index number of the chosen article (e.g., '3'). Do not add any explanation.",
        articles_text
    )
}

/// Phase 1: shortlist the top 5 candidates from headlines.
pub fn shortlist_prompt(articles_text: &str) -> String {
    format!(
        "You are an expert Software Engineering Editor. From the following headlines, shortlist the 5 most promising articles for a senior software engineer. Consider technical depth, novelty, and educational value.\n\n{}\n\nReply ONLY with 5 comma-separated index numbers (e.g., '3,7,12,25,41'). No explanation.",
        articles_text
    )
}

/// Phase 2: pick one from the shortlist using content snippets.
pub fn final_selection_prompt(candidates_text: &str) -> String {
    format!(
        "You are an expert Software Engineering Editor. Below are 5 candidate articles with content previews. Select the SINGLE best article — the one with the most substantive, technically deep content (not just an appealing headline).\n\n{}\n\nReply ONLY with the index number of the chosen article (e.g., '3'). No explanation.",
        candidates_text
    )
}

/// Shortlist prompt with optional selection feedback and recent picks context.
pub fn shortlist_prompt_with_context(
    articles_text: &str,
    selection_context: Option<&str>,
    recent_picks: Option<&str>,
) -> String {
    inject_context(
        shortlist_prompt(articles_text),
        selection_context,
        recent_picks,
    )
}

/// Final selection prompt with optional context.
pub fn final_selection_prompt_with_context(
    candidates_text: &str,
    selection_context: Option<&str>,
    recent_picks: Option<&str>,
) -> String {
    inject_context(
        final_selection_prompt(candidates_text),
        selection_context,
        recent_picks,
    )
}

/// The V3 Insight Brief: structured JSON summary of the selected article.
pub fn summary_prompt(source: &str, title: &str, content: &str) -> String {
    format!(
        r#"You are writing an insight brief for a senior engineering leader who builds developer platforms at a hedge fund (C++/Rust, low-latency, AI tooling). They'll read this on their phone in 2-3 minutes.

Extract the single most important insight from this article and structure it as JSON.

Output ONLY valid JSON matching this schema:
{{
  "key_idea": "One sentence. The distilled insight — the 'so what'. No hedging.",
  "why_it_matters": "2-3 sentences. Why this matters to someone building low-latency systems and developer platforms.",
  "what_to_change": "One concrete action to try this week, or null if the article doesn't support one. Never invent advice.",
  "deep_dive": "Full technical analysis in markdown. 3-5 paragraphs. Include specific numbers, techniques, trade-offs. Be dense — every sentence should teach something.",
  "meta": {{
    "confidence": 0.85,
    "category": "one of: performance-engineering, ai-tooling, platform-engineering, leadership, trading-systems, architecture, general"
  }}
}}

Rules:
- key_idea must be one sentence, direct and opinionated
- why_it_matters must connect to the reader's specific context
- deep_dive uses markdown formatting (bold, bullets, code) for scannability
- Be compact — say it in fewer words, not more
- No fluff, no filler transitions, no "in conclusion"
- Ignore promotional content

Article Source: {}
Title: {}
Content: {}"#,
        source, title, content
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prompt_version() {
        assert_eq!(PROMPT_VERSION, "v3");
    }

    #[test]
    fn test_selection_prompt_contains_articles() {
        let prompt = selection_prompt("0. [HN] Test Article");
        assert!(prompt.contains("0. [HN] Test Article"));
        assert!(prompt.contains("expert Software Engineering Editor"));
    }

    #[test]
    fn test_shortlist_prompt_asks_for_five() {
        let prompt = shortlist_prompt("0. [HN] Test Article");
        assert!(prompt.contains("0. [HN] Test Article"));
        assert!(prompt.contains("5 comma-separated index numbers"));
    }

    #[test]
    fn test_final_selection_prompt_contains_candidates() {
        let prompt = final_selection_prompt("--- Article 3 ---\n[HN] Test");
        assert!(prompt.contains("--- Article 3 ---"));
        assert!(prompt.contains("Reply ONLY with the index number"));
    }

    #[test]
    fn test_summary_prompt_requests_json() {
        let prompt = summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("key_idea"));
        assert!(prompt.contains("why_it_matters"));
        assert!(prompt.contains("what_to_change"));
        assert!(prompt.contains("deep_dive"));
        assert!(prompt.contains("Output ONLY valid JSON"));
        assert!(prompt.contains("Article Source: HN"));
    }

    #[test]
    fn test_shortlist_with_context_includes_feedback() {
        let prompt = shortlist_prompt_with_context(
            "0. [HN] Test",
            Some("Recent reader feedback:\n- Liked: \"Rust Perf\"\n"),
            None,
        );
        assert!(prompt.contains("Liked: \"Rust Perf\""));
        assert!(prompt.contains("0. [HN] Test"));
    }

    #[test]
    fn test_shortlist_with_context_none_is_base() {
        let base = shortlist_prompt("0. [HN] Test");
        let with_ctx = shortlist_prompt_with_context("0. [HN] Test", None, None);
        assert_eq!(base, with_ctx);
    }

    #[test]
    fn test_final_selection_with_context_orders_picks_then_feedback() {
        let prompt = final_selection_prompt_with_context(
            "--- Article 0 ---",
            Some("FEEDBACK"),
            Some("PICKS"),
        );
        let picks = prompt.find("PICKS").unwrap();
        let feedback = prompt.find("FEEDBACK").unwrap();
        let body = prompt.find("--- Article 0 ---").unwrap();
        assert!(picks < feedback && feedback < body);
    }
}
