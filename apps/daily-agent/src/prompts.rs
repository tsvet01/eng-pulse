/// Prompt configuration for article selection and summarization.
/// V1 = production (current prompts). V2 = beta (persona-driven, structured).
pub enum PromptConfig {
    V1,
    V2,
}

impl PromptConfig {
    /// Version string for manifest tagging.
    pub fn version(&self) -> &'static str {
        match self {
            Self::V1 => "v1",
            Self::V2 => "v2",
        }
    }

    /// Build the article selection prompt.
    pub fn selection_prompt(&self, articles_text: &str) -> String {
        match self {
            Self::V1 => self.v1_selection_prompt(articles_text),
            Self::V2 => self.v2_selection_prompt(articles_text),
        }
    }

    /// Build the article summarization prompt.
    pub fn summary_prompt(&self, source: &str, title: &str, content: &str) -> String {
        match self {
            Self::V1 => self.v1_summary_prompt(source, title, content),
            Self::V2 => self.v2_summary_prompt(source, title, content),
        }
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
}
