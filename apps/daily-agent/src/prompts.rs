/// Prompt configuration for article selection and summarization.
/// V1 = production (current prompts). V2 = beta (persona-driven, structured).
pub struct PromptConfig {
    pub version: &'static str,
}

impl PromptConfig {
    pub const V1: Self = Self { version: "v1" };
    pub const V2: Self = Self { version: "v2" };

    /// Build the article selection prompt.
    pub fn selection_prompt(&self, articles_text: &str) -> String {
        match self.version {
            "v2" => self.v2_selection_prompt(articles_text),
            _ => self.v1_selection_prompt(articles_text),
        }
    }

    /// Build the article summarization prompt.
    pub fn summary_prompt(&self, source: &str, title: &str, content: &str) -> String {
        match self.version {
            "v2" => self.v2_summary_prompt(source, title, content),
            _ => self.v1_summary_prompt(source, title, content),
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

Engineering leader and systems programmer (C++/Rust/Python/Go) in quantitative finance, building developer platforms at a hedge fund in London. 20 years across storage systems, derivatives risk, and WhatsApp commerce. Obsessed with low-level performance, AI-assisted development, and the builder-vs-manager tension.

Their interest areas: C++ (modern standards, performance, SIMD), Rust (systems, async), Python (typing, performance), low-latency computing, distributed systems, CI/CD & build systems, platform engineering, LLM-assisted coding (agentic workflows, MCP), AI engineering (RAG, tool use), trading systems architecture, real-time risk/P&L, engineering leadership (Staff/Principal paths, IC vs manager), Neovim/terminal tooling, adult developmental psychology.

From today's articles, select the SINGLE most valuable one. Prioritize:
1. Actionable insight they can apply this week
2. Technical depth — not surface-level news or beginner content
3. Novelty — fresh perspective, not common knowledge
4. Relevance to their specific role and interests

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
            r#"Summarize this article in exactly this structure (400-500 words total):

## {{concise title, 8-12 words}}

**{{one-line hook: why this matters to an engineering leader}}**

### Key Points
- **{{bold lead phrase}}**: {{explanation}}
(3-5 bullets, each self-contained)

### Why It Matters
{{2-3 sentences connecting to real engineering work — architecture decisions, team impact, or industry shift}}

### Action Items
- {{1-2 specific, concrete things to evaluate or do this week}}

Rules:
- Reader is a senior engineering leader who builds developer platforms at a hedge fund
- No fluff, no filler, no "in conclusion", no "in summary"
- Bold the lead phrase of each bullet for scannability
- Each paragraph max 50 words (mobile readability)
- Be specific and opinionated, not hedging
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
        assert!(prompt.contains("quantitative finance"));
        assert!(prompt.contains("0. [HN] Test Article"));
    }

    #[test]
    fn test_v1_summary_prompt_contains_article() {
        let prompt = PromptConfig::V1.summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("Article Source: HN"));
        assert!(prompt.contains("Title: Title"));
    }

    #[test]
    fn test_v2_summary_prompt_has_structure() {
        let prompt = PromptConfig::V2.summary_prompt("HN", "Title", "Content");
        assert!(prompt.contains("### Key Points"));
        assert!(prompt.contains("### Why It Matters"));
        assert!(prompt.contains("### Action Items"));
        assert!(prompt.contains("400-500 words"));
    }
}
