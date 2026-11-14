//! Production prompts for the daily run: two-phase article selection and the
//! V3 Insight Brief. Prompt wording is a tuned artifact; change only on request.
//! Reply shapes are enforced by the schemas passed to `call_llm_typed`.

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
        "You are an expert Software Engineering Editor. Review the following list of article headlines collected today. Select the SINGLE most valuable, educational, and impactful article for a senior software engineer to read. Consider technical depth, novelty, and broad relevance.\n\n{}\n\nReturn the index number of the chosen article. Do not add any explanation.",
        articles_text
    )
}

/// Phase 1: shortlist the top 5 candidates from headlines.
pub fn shortlist_prompt(articles_text: &str) -> String {
    format!(
        "You are an expert Software Engineering Editor. From the following headlines, shortlist the 5 most promising articles for a senior software engineer. Consider technical depth, novelty, and educational value.\n\n{}\n\nReturn the index numbers of the 5 chosen articles, best first. No explanation.",
        articles_text
    )
}

/// Phase 2: pick one from the shortlist using content snippets.
pub fn final_selection_prompt(candidates_text: &str) -> String {
    format!(
        "You are an expert Software Engineering Editor. Below are 5 candidate articles with content previews. Select the SINGLE best article — the one with the most substantive, technically deep content (not just an appealing headline).\n\n{}\n\nReturn the index number of the chosen article. No explanation.",
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
        r#"You are writing an insight brief for experienced software engineers. Readers span systems programming (C++, Rust), Python, AI and agentic engineering, data, and platforms, and each follows different interests. They'll read this on their phone in 2-3 minutes.

Extract the single most important insight from this article and structure it as JSON.

Output ONLY valid JSON matching this schema:
{{
  "key_idea": "One sentence. The distilled insight — the 'so what'. No hedging.",
  "why_it_matters": "2-3 sentences. The practical consequence for engineers working in the article's own domain.",
  "what_to_change": "One concrete action to try this week, written as a clear, simple step, or null if the article doesn't support one. Never invent advice.",
  "deep_dive": "Explain how it works, in markdown. 3-5 short paragraphs: first the concrete problem, then the mechanism that solves it step by step, then the article's own numbers and trade-offs. A reader who has not seen the article should be able to explain the mechanism afterwards.",
  "meta": {{
    "confidence": 0.85,
    "category": "one of: performance-engineering, ai-tooling, platform-engineering, leadership, trading-systems, architecture, general"
  }}
}}

Rules:
- Write all reader-facing text in English, including titles, headings, quotations, and JSON string values, regardless of the source language. Translate non-English prose; use English names or transliterations for proper nouns. Preserve code, URLs, and technical identifiers.
- key_idea must be one sentence, direct and opinionated
- why_it_matters states the consequence directly, in the article's own domain
- Never name or describe the audience: no "For a ... team" or "For ... engineers" openers, no employer, industry, or role
- Do not tie the article to a language, industry, or domain it does not discuss
- Use plain, simple language and short sentences. Prefer the everyday word; define a term the first time if the article's readers might not know it.
- Be concrete: explain the specific mechanism and name the specifics from the article. Do not replace them with a general principle or mental model.
- Every number, name and mechanism must come from the article. If the article does not say it, leave it out.
- deep_dive uses light markdown (bold lead-ins, short bullets, code). No tables. Keep it short enough to read in 2-3 minutes.
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
    fn test_summary_prompt_asks_for_concrete_grounded_briefs() {
        let prompt = summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("first the concrete problem, then the mechanism"));
        assert!(prompt.contains("must come from the article"));
        assert!(prompt.contains("No tables"));
    }

    #[test]
    fn test_summary_requires_english_for_russian_source() {
        let prompt = summary_prompt("Habr", "Оптимизация Rust", "Русский текст статьи");
        assert!(prompt.contains("Write all reader-facing text in English"));
        assert!(prompt.contains("including titles, headings, quotations, and JSON string values"));
        assert!(prompt.contains("Оптимизация Rust"));
    }

    #[test]
    fn test_summary_prompt_names_no_reader_persona() {
        let prompt = summary_prompt("HN", "Title", "Content");
        for phrase in ["hedge fund", "low-latency", "engineering leader"] {
            assert!(!prompt.contains(phrase), "persona phrase: {phrase}");
        }
        assert!(prompt.contains("Python") && prompt.contains("agentic"));
        assert!(prompt.contains("Never name or describe the audience"));
    }

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
        assert!(prompt.contains("index numbers of the 5 chosen articles"));
    }

    #[test]
    fn test_final_selection_prompt_contains_candidates() {
        let prompt = final_selection_prompt("--- Article 3 ---\n[HN] Test");
        assert!(prompt.contains("--- Article 3 ---"));
        assert!(prompt.contains("Return the index number of the chosen article"));
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
