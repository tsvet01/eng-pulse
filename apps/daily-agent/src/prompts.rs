/// Prompt configuration for article selection and summarization.
/// V1 = production (current prompts). V2 = beta (persona-driven, structured). V3 = beta (persona-driven selection + structured JSON summary).
pub enum PromptConfig {
    V1,
    V2,
    V3,
}

impl PromptConfig {
    /// Version string for manifest tagging.
    pub fn version(&self) -> &'static str {
        match self {
            Self::V1 => "v1",
            Self::V2 => "v2",
            Self::V3 => "v3",
        }
    }

    /// Build the article selection prompt (headline-only, single pick).
    pub fn selection_prompt(&self, articles_text: &str) -> String {
        match self {
            Self::V1 => self.v1_selection_prompt(articles_text),
            Self::V2 => self.v2_selection_prompt(articles_text),
            Self::V3 => self.v2_selection_prompt(articles_text),
        }
    }

    /// Build the shortlist prompt (pick top 5 candidates from headlines).
    pub fn shortlist_prompt(&self, articles_text: &str) -> String {
        match self {
            Self::V1 => self.v1_shortlist_prompt(articles_text),
            Self::V2 => self.v2_shortlist_prompt(articles_text),
            Self::V3 => self.v2_shortlist_prompt(articles_text),
        }
    }

    /// Build the final selection prompt (pick 1 from shortlist with content snippets).
    pub fn final_selection_prompt(&self, candidates_text: &str) -> String {
        match self {
            Self::V1 => self.v1_final_selection_prompt(candidates_text),
            Self::V2 => self.v2_final_selection_prompt(candidates_text),
            Self::V3 => self.v2_final_selection_prompt(candidates_text),
        }
    }

    /// Build the article summarization prompt.
    pub fn summary_prompt(&self, source: &str, title: &str, content: &str) -> String {
        match self {
            Self::V1 => self.v1_summary_prompt(source, title, content),
            Self::V2 => self.v2_summary_prompt(source, title, content),
            Self::V3 => self.v3_summary_prompt(source, title, content),
        }
    }

    /// Build shortlist prompt with optional selection feedback and recent picks context.
    pub fn shortlist_prompt_with_context(
        &self,
        articles_text: &str,
        selection_context: Option<&str>,
        recent_picks: Option<&str>,
    ) -> String {
        let base = self.shortlist_prompt(articles_text);
        let mut prompt = base;
        if let Some(ctx) = selection_context {
            prompt = format!("{}\n\n{}", ctx, prompt);
        }
        if let Some(picks) = recent_picks {
            prompt = format!("{}\n\n{}", picks, prompt);
        }
        prompt
    }

    /// Build final selection prompt with optional context.
    pub fn final_selection_prompt_with_context(
        &self,
        candidates_text: &str,
        selection_context: Option<&str>,
        recent_picks: Option<&str>,
    ) -> String {
        let base = self.final_selection_prompt(candidates_text);
        let mut prompt = base;
        if let Some(ctx) = selection_context {
            prompt = format!("{}\n\n{}", ctx, prompt);
        }
        if let Some(picks) = recent_picks {
            prompt = format!("{}\n\n{}", picks, prompt);
        }
        prompt
    }

    fn v1_selection_prompt(&self, articles_text: &str) -> String {
        format!(
            "You are an expert Software Engineering Editor. Review the following list of article headlines collected today. Select the SINGLE most valuable, educational, and impactful article for a senior software engineer to read. Consider technical depth, novelty, and broad relevance.\n\n{}\n\nReply ONLY with the integer index number of the chosen article (e.g., '3'). Do not add any explanation.",
            articles_text
        )
    }

    fn v2_selection_prompt(&self, articles_text: &str) -> String {
        format!(
            r#"You are curating a daily technical digest for this reader:

Engineering leader building developer platforms at a hedge fund in London. Systems programmer (C++/Rust) with 20 years across low-latency trading, storage systems, and developer tooling.

Top interests (ranked):
1. Low-latency systems and performance engineering (C++, Rust, SIMD)
2. AI-assisted development and agentic coding workflows
3. Platform engineering and developer experience
4. Engineering leadership — Staff/Principal IC paths
5. Trading systems architecture and real-time risk

From today's articles, select the SINGLE most valuable one. Prioritize:
1. Actionable insight they can apply this week
2. Technical depth — not surface-level news or beginner content
3. Novelty — fresh perspective, not common knowledge

When criteria conflict, prefer actionability over novelty, and depth over breadth.

Avoid: product announcements, vendor marketing, beginner tutorials, pure news without insight.

{}

Reply ONLY with the integer index number (e.g., '3'). No explanation."#,
            articles_text
        )
    }

    fn v1_shortlist_prompt(&self, articles_text: &str) -> String {
        format!(
            "You are an expert Software Engineering Editor. From the following headlines, shortlist the 5 most promising articles for a senior software engineer. Consider technical depth, novelty, and educational value.\n\n{}\n\nReply ONLY with 5 comma-separated index numbers (e.g., '3,7,12,25,41'). No explanation.",
            articles_text
        )
    }

    fn v2_shortlist_prompt(&self, articles_text: &str) -> String {
        format!(
            r#"You are curating a daily technical digest for this reader:

Engineering leader building developer platforms at a hedge fund in London. Systems programmer (C++/Rust) with 20 years across low-latency trading, storage systems, and developer tooling.

Top interests (ranked):
1. Low-latency systems and performance engineering (C++, Rust, SIMD)
2. AI-assisted development and agentic coding workflows
3. Platform engineering and developer experience
4. Engineering leadership — Staff/Principal IC paths
5. Trading systems architecture and real-time risk

From today's articles, shortlist the 5 most promising candidates. Prioritize:
1. Actionable insight they can apply this week
2. Technical depth — not surface-level news or beginner content
3. Novelty — fresh perspective, not common knowledge

Avoid: product announcements, vendor marketing, beginner tutorials, pure news without insight.

{}

Reply ONLY with 5 comma-separated index numbers (e.g., '3,7,12,25,41'). No explanation."#,
            articles_text
        )
    }

    fn v1_final_selection_prompt(&self, candidates_text: &str) -> String {
        format!(
            "You are an expert Software Engineering Editor. Below are 5 candidate articles with content previews. Select the SINGLE best article — the one with the most substantive, technically deep content (not just an appealing headline).\n\n{}\n\nReply ONLY with the index number of the chosen article (e.g., '3'). No explanation.",
            candidates_text
        )
    }

    fn v2_final_selection_prompt(&self, candidates_text: &str) -> String {
        format!(
            r#"You are making the final pick for a daily technical digest. The reader is a senior engineering leader at a hedge fund (C++/Rust, low-latency, AI tooling).

Below are 5 candidate articles with content previews. Now that you can see the actual content, select the SINGLE best one. Look for:
- Substantive technical depth (not just a catchy headline)
- Actionable insight, not surface-level reporting
- Content density — every paragraph teaches something

{}

Reply ONLY with the index number (e.g., '3'). No explanation."#,
            candidates_text
        )
    }

    fn v1_summary_prompt(&self, source: &str, title: &str, content: &str) -> String {
        format!(
            "Please summarize the following software engineering article in a compact and educational format. Focus on key takeaways, core concepts, and why it matters to a software engineer. Ignore any promotional or fluff content.\n\nArticle Source: {}\nTitle: {}\nContent: {}",
            source, title, content
        )
    }

    fn v2_summary_prompt(&self, source: &str, title: &str, content: &str) -> String {
        format!(
            r#"Summarize this article for a senior engineering leader who builds developer platforms at a hedge fund (C++/Rust, low-latency, AI tooling). They'll read this on their phone in 2-3 minutes.

Lead with a one-line hook: why this matters to them specifically. Then cover the key insights — use bold lead phrases and bullets for scannability, but match the structure to the content. Some articles warrant 3 bullets; others need 2 paragraphs.

If the article suggests something concrete to try or evaluate this week, end with that. If it doesn't, don't invent action items.

Rules:
- Be compact — say it in fewer words, not more
- No fluff: no "in conclusion", no "in summary", no filler transitions
- Be direct and opinionated — state what matters, skip the hedging
- Ignore promotional content

Article Source: {}
Title: {}
Content: {}"#,
            source, title, content
        )
    }

    fn v3_summary_prompt(&self, source: &str, title: &str, content: &str) -> String {
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_v1_selection_prompt_contains_articles() {
        let prompt = PromptConfig::V1.selection_prompt("0. [HN] Test Article");
        assert!(prompt.contains("0. [HN] Test Article"));
        assert!(prompt.contains("expert Software Engineering Editor"));
    }

    #[test]
    fn test_v2_selection_prompt_contains_persona() {
        let prompt = PromptConfig::V2.selection_prompt("0. [HN] Test Article");
        assert!(prompt.contains("hedge fund"));
        assert!(prompt.contains("prefer actionability over novelty"));
        assert!(prompt.contains("0. [HN] Test Article"));
    }

    #[test]
    fn test_v1_summary_prompt_contains_article() {
        let prompt = PromptConfig::V1.summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("Article Source: HN"));
        assert!(prompt.contains("Title: Title"));
    }

    #[test]
    fn test_v2_summary_prompt_has_persona_and_rules() {
        let prompt = PromptConfig::V2.summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("senior engineering leader who builds developer platforms"));
        assert!(prompt.contains("bold lead phrases and bullets"));
        assert!(prompt.contains("don't invent action items"));
        assert!(prompt.contains("Be compact"));
        assert!(prompt.contains("Article Source: HN"));
    }

    #[test]
    fn test_v3_version_string() {
        assert_eq!(PromptConfig::V3.version(), "v3");
    }

    #[test]
    fn test_v3_selection_uses_v2_persona() {
        let prompt = PromptConfig::V3.selection_prompt("0. [HN] Test Article");
        assert!(prompt.contains("hedge fund"));
        assert!(prompt.contains("0. [HN] Test Article"));
    }

    #[test]
    fn test_v3_summary_prompt_requests_json() {
        let prompt = PromptConfig::V3.summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("key_idea"));
        assert!(prompt.contains("why_it_matters"));
        assert!(prompt.contains("what_to_change"));
        assert!(prompt.contains("deep_dive"));
        assert!(prompt.contains("Output ONLY valid JSON"));
        assert!(prompt.contains("Article Source: HN"));
    }

    #[test]
    fn test_shortlist_with_context_includes_feedback() {
        let prompt = PromptConfig::V3.shortlist_prompt_with_context(
            "0. [HN] Test",
            Some("Recent reader feedback:\n- Liked: \"Rust Perf\"\n"),
            None,
        );
        assert!(prompt.contains("Liked: \"Rust Perf\""));
        assert!(prompt.contains("0. [HN] Test"));
    }

    #[test]
    fn test_shortlist_with_context_none_is_base() {
        let base = PromptConfig::V3.shortlist_prompt("0. [HN] Test");
        let with_ctx = PromptConfig::V3.shortlist_prompt_with_context("0. [HN] Test", None, None);
        assert_eq!(base, with_ctx);
    }
}
