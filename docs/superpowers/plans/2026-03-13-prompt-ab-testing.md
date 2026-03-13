# Prompt A/B Testing Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add parallel beta prompt pipeline with eval scoring and mobile A/B comparison UI.

**Architecture:** Four-stage pipeline in daily-agent (fetch → prod → beta → eval). Prompts extracted to a config module. Mobile apps gain version filter, eval score display, and feedback buttons (Swift) / reuse existing feedback (Flutter).

**Tech Stack:** Rust (daily-agent), Swift/SwiftUI (iOS), Flutter/Dart (mobile), GCS (storage)

**Spec:** `docs/superpowers/specs/2026-03-13-prompt-ab-testing-design.md`

---

## Chunk 1: Rust — Prompt Module & Pipeline

### Task 1: Create prompt configuration module

**Files:**
- Create: `apps/daily-agent/src/prompts.rs`
- Modify: `apps/daily-agent/src/main.rs:1` (add `mod prompts;`)

- [ ] **Step 1: Create `prompts.rs` with V1 and V2 prompt configs**

```rust
// apps/daily-agent/src/prompts.rs

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
```

- [ ] **Step 2: Add `mod prompts;` to main.rs**

Add after line 1 of `apps/daily-agent/src/main.rs`:
```rust
mod prompts;
```

- [ ] **Step 3: Run tests**

Run: `cd apps/daily-agent && cargo test prompts`
Expected: All 4 tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/daily-agent/src/prompts.rs apps/daily-agent/src/main.rs
git commit -m "feat: add prompt configuration module with v1/v2 configs"
```

### Task 2: Add manifest schema fields and eval structs

**Files:**
- Modify: `apps/daily-agent/src/main.rs:42-56` (ManifestEntry struct)

- [ ] **Step 1: Add `prompt_version` and `eval_score` to ManifestEntry**

In `apps/daily-agent/src/main.rs`, add after line 55 (`selected_by` field), before the closing `}`:

```rust
    /// Which prompt version generated this summary ("v2" for beta, null for prod)
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_version: Option<String>,
    /// Quality score from LLM judge (0.0-1.0)
    #[serde(skip_serializing_if = "Option::is_none")]
    eval_score: Option<f64>,
```

- [ ] **Step 2: Add eval structs after ManifestEntry**

Add after the ManifestEntry struct (after line 56):

```rust
/// Eval report stored in GCS at eval/{date}.json
#[derive(Serialize, Deserialize, Debug, Clone)]
struct EvalReport {
    date: String,
    scores: Vec<EvalEntry>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct EvalEntry {
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
struct EvalCriteria {
    clarity: u8,
    actionability: u8,
    information_density: u8,
    structure: u8,
}
```

- [ ] **Step 3: Update all ManifestEntry constructions to include new fields**

Find the existing `ManifestEntry { ... }` construction (around line 243-251) and add the two new fields:

```rust
    prompt_version: None,
    eval_score: None,
```

- [ ] **Step 4: Run `cargo check`**

Run: `cd apps/daily-agent && cargo check`
Expected: Compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: add prompt_version and eval_score to manifest schema"
```

### Task 3: Refactor main.rs to use PromptConfig for prod pipeline

**Files:**
- Modify: `apps/daily-agent/src/main.rs:150-206` (selection and summary prompt construction)

- [ ] **Step 1: Replace inline selection prompt with PromptConfig::V1**

Replace the selection prompt construction (lines 150-158) with:

```rust
    let mut articles_text = String::new();
    for (i, article) in all_articles.iter().enumerate() {
        articles_text.push_str(&format!("{}. [{}] {}\n", i, article.source, article.title));
    }

    let prod_config = prompts::PromptConfig::V1;
    let selection_prompt = prod_config.selection_prompt(&articles_text);
```

- [ ] **Step 2: Replace inline summary prompt with PromptConfig::V1**

Replace the summary prompt construction (lines 203-206) with:

```rust
    let summary_prompt = prod_config.summary_prompt(&best_article.source, &best_article.title, &truncated_text);
```

- [ ] **Step 3: Run all tests**

Run: `cd apps/daily-agent && cargo test`
Expected: All existing tests pass (prompt content is identical).

- [ ] **Step 4: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "refactor: use PromptConfig for prod prompt construction"
```

### Task 4: Add beta pipeline (Stage 3)

**Files:**
- Modify: `apps/daily-agent/src/main.rs` (add beta stage after prod stage)

- [ ] **Step 1: Restructure manifest handling — download once, upload once**

Move the manifest download to BEFORE Stage 2 (prod). Remove the existing manifest download/upload block (lines 274-316). Instead:

1. Download manifest right after sources loading (around line 124), storing it in `let mut manifest: Vec<ManifestEntry>`.
2. Remove today's entries: `manifest.retain(|e| e.date != today);`
3. Collect all new entries in `let mut new_manifest_entries: Vec<ManifestEntry>` (already exists).
4. After ALL stages complete, insert new entries and upload once.

The final upload block (at the very end of main, after eval stage):

```rust
    // Final: Upload manifest (all stages have appended to new_manifest_entries)
    for entry in new_manifest_entries.into_iter().rev() {
        manifest.insert(0, entry);
    }
    let manifest_json = serde_json::to_vec_pretty(&manifest)?;
    gcs_client.upload_object(
        &UploadObjectRequest {
            bucket: bucket_name.to_string(),
            ..Default::default()
        },
        manifest_json,
        &UploadType::Simple(Media::new("manifest.json".to_string()))
    ).await?;
    info!(date = %today, "Manifest updated successfully");
```

- [ ] **Step 2: Add beta stage after prod summaries are uploaded**

After the prod summary loop ends and before the manifest upload, add:

```rust
    // --- Stage 3: Beta (v2) ---
    // Only runs if Claude API key is available
    let claude_entry = enabled_providers.iter().find(|(p, _)| *p == LlmProvider::Claude);
    if let Some((_, claude_key)) = claude_entry {
        info!("Starting beta pipeline (v2)");
        let beta_config = prompts::PromptConfig::V2;

        // Beta selection: pick a different article using persona-driven prompt
        let beta_selection_prompt = beta_config.selection_prompt(&articles_text);
        match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, beta_selection_prompt).await {
            Ok(beta_selected) => {
                let beta_index = parse_selection_index(&beta_selected).unwrap_or(0);
                let beta_safe_index = if beta_index >= all_articles.len() { 0 } else { beta_index };
                let beta_article = &all_articles[beta_safe_index];
                info!(title = %beta_article.title, "Beta selected article");

                // V2 summary of prod article A (guaranteed comparison)
                let beta_summary_prompt_a = beta_config.summary_prompt(
                    &best_article.source, &best_article.title, &truncated_text
                );
                match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, beta_summary_prompt_a).await {
                    Ok(summary) => {
                        let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();
                        let object_name = format!("summaries/beta/claude/{}.md", today);
                        let summary_bytes = summary.into_bytes();

                        match gcs_client.upload_object(
                            &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                            summary_bytes,
                            &UploadType::Simple(Media::new(object_name.clone()))
                        ).await {
                            Ok(_) => {
                                let public_url = format!("https://storage.googleapis.com/{}/{}", bucket_name, object_name);
                                new_manifest_entries.push(ManifestEntry {
                                    date: today.clone(),
                                    url: public_url,
                                    title: best_article.title.clone(),
                                    summary_snippet,
                                    original_url: Some(best_article.url.clone()),
                                    model: Some(LlmProvider::Claude.model_name().to_string()),
                                    selected_by: Some(selection_provider.model_name().to_string()),
                                    prompt_version: Some("v2".to_string()),
                                    eval_score: None,
                                });
                                info!("Beta summary of prod article uploaded");
                            }
                            Err(e) => warn!(error = %e, "Failed to upload beta summary of prod article"),
                        }
                    }
                    Err(e) => warn!(error = %e, "Failed to generate beta summary of prod article"),
                }

                // V2 summary of beta article B (only if different from A)
                if beta_article.url != best_article.url {
                    info!(title = %beta_article.title, "Beta article differs from prod, generating summary");
                    let beta_article_content = match fetch_article_content(&http_client, &beta_article.url).await {
                        Ok(content) => content,
                        Err(e) => {
                            warn!(error = %e, "Failed to fetch beta article content, using title");
                            format!("Title: {}, URL: {}", beta_article.title, beta_article.url)
                        }
                    };
                    let beta_truncated: String = beta_article_content.chars().take(MAX_ARTICLE_CHARS).collect();
                    let beta_summary_prompt_b = beta_config.summary_prompt(
                        &beta_article.source, &beta_article.title, &beta_truncated
                    );
                    match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, beta_summary_prompt_b).await {
                        Ok(summary) => {
                            let summary_snippet: String = summary.chars().take(SUMMARY_SNIPPET_CHARS).collect();
                            let object_name = format!("summaries/beta/claude/{}-selection.md", today);
                            let summary_bytes = summary.into_bytes();

                            match gcs_client.upload_object(
                                &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                                summary_bytes,
                                &UploadType::Simple(Media::new(object_name.clone()))
                            ).await {
                                Ok(_) => {
                                    let public_url = format!("https://storage.googleapis.com/{}/{}", bucket_name, object_name);
                                    new_manifest_entries.push(ManifestEntry {
                                        date: today.clone(),
                                        url: public_url,
                                        title: beta_article.title.clone(),
                                        summary_snippet,
                                        original_url: Some(beta_article.url.clone()),
                                        model: Some(LlmProvider::Claude.model_name().to_string()),
                                        selected_by: Some(format!("{} (v2)", LlmProvider::Claude.model_name())),
                                        prompt_version: Some("v2".to_string()),
                                        eval_score: None,
                                    });
                                    info!("Beta summary of beta article uploaded");
                                }
                                Err(e) => warn!(error = %e, "Failed to upload beta selection summary"),
                            }
                        }
                        Err(e) => warn!(error = %e, "Failed to generate beta selection summary"),
                    }
                } else {
                    info!("Beta selected same article as prod, skipping duplicate summary");
                }
            }
            Err(e) => warn!(error = %e, "Beta selection failed, skipping beta pipeline"),
        }
    } else {
        info!("ANTHROPIC_API_KEY not set, skipping beta pipeline");
    }
```

- [ ] **Step 3: Run `cargo check`**

Run: `cd apps/daily-agent && cargo check`
Expected: Compiles without errors.

- [ ] **Step 4: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: add beta pipeline stage with v2 persona-driven prompts"
```

### Task 5: Add eval stage (Stage 4)

**Files:**
- Modify: `apps/daily-agent/src/main.rs` (add eval stage after beta)

- [ ] **Step 1: Add eval stage after beta pipeline, before manifest upload**

```rust
    // --- Stage 4: Eval ---
    if let Some((_, claude_key)) = claude_entry {
        info!("Starting eval stage");

        // Collect all summaries generated today for evaluation
        let mut eval_summaries: Vec<(String, String)> = Vec::new(); // (summary_id, content)

        for entry in &new_manifest_entries {
            let provider = entry.model.as_deref().unwrap_or("unknown");
            let version = entry.prompt_version.as_deref().unwrap_or("v1");
            let suffix = if entry.url.contains("-selection.md") { "-selection" } else { "" };
            let summary_id = format!("{}-{}{}", version, provider.split('-').next().unwrap_or(provider), suffix);

            // Download the summary we just uploaded
            match gcs_client.download_object(
                &GetObjectRequest {
                    bucket: bucket_name.to_string(),
                    object: entry.url.replace(&format!("https://storage.googleapis.com/{}/", bucket_name), ""),
                    ..Default::default()
                },
                &Range::default()
            ).await {
                Ok(data) => {
                    if let Ok(content) = String::from_utf8(data) {
                        eval_summaries.push((summary_id, content));
                    }
                }
                Err(e) => warn!(summary_id = %summary_id, error = %e, "Failed to download summary for eval"),
            }
        }

        if !eval_summaries.is_empty() {
            let mut eval_prompt = String::from(
                "You are evaluating article summaries for quality. Score each summary on these criteria (1-5):\n\n\
                1. Clarity: How easy is it to scan and understand on a mobile phone?\n\
                2. Actionability: Does it provide concrete takeaways the reader can act on this week?\n\
                3. Information density: What is the signal-to-noise ratio? Is every sentence valuable?\n\
                4. Structure: Is it well-formatted with clear sections, bold key phrases, scannable bullets?\n\n\
                The reader is a senior engineering leader. They have 2-3 minutes on their phone.\n\n\
                For each summary below, return ONLY a JSON object (no markdown fences):\n\
                {\"scores\": [{\"summary_id\": \"id\", \"clarity\": N, \"actionability\": N, \"information_density\": N, \"structure\": N, \"reasoning\": \"...\"}]}\n\n"
            );

            for (id, content) in &eval_summaries {
                eval_prompt.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
            }

            match call_llm_with_retry(&http_client, LlmProvider::Claude, claude_key, eval_prompt).await {
                Ok(eval_response) => {
                    // Parse JSON from response (handle possible markdown fences)
                    let cleaned = eval_response
                        .trim()
                        .trim_start_matches("```json")
                        .trim_start_matches("```")
                        .trim_end_matches("```")
                        .trim();

                    match serde_json::from_str::<serde_json::Value>(cleaned) {
                        Ok(json) => {
                            if let Some(scores) = json.get("scores").and_then(|s| s.as_array()) {
                                for score in scores {
                                    let summary_id = score.get("summary_id").and_then(|s| s.as_str()).unwrap_or("");
                                    let clarity = score.get("clarity").and_then(|v| v.as_u64()).unwrap_or(3) as u8;
                                    let actionability = score.get("actionability").and_then(|v| v.as_u64()).unwrap_or(3) as u8;
                                    let info_density = score.get("information_density").and_then(|v| v.as_u64()).unwrap_or(3) as u8;
                                    let structure = score.get("structure").and_then(|v| v.as_u64()).unwrap_or(3) as u8;
                                    let total = (clarity as f64 + actionability as f64 + info_density as f64 + structure as f64) / 20.0;
                                    let reasoning = score.get("reasoning").and_then(|s| s.as_str()).unwrap_or("").to_string();

                                    info!(summary_id = %summary_id, total = %total, reasoning = %reasoning, "Eval score");

                                    // Update matching manifest entry
                                    for entry in &mut new_manifest_entries {
                                        let provider = entry.model.as_deref().unwrap_or("unknown");
                                        let version = entry.prompt_version.as_deref().unwrap_or("v1");
                                        let suffix = if entry.url.contains("-selection.md") { "-selection" } else { "" };
                                        let entry_id = format!("{}-{}{}", version, provider.split('-').next().unwrap_or(provider), suffix);
                                        if entry_id == summary_id {
                                            entry.eval_score = Some(total);
                                        }
                                    }
                                }
                            }

                            // Upload eval report
                            let eval_object = format!("eval/{}.json", today);
                            if let Ok(eval_json) = serde_json::to_vec_pretty(&json) {
                                match gcs_client.upload_object(
                                    &UploadObjectRequest { bucket: bucket_name.to_string(), ..Default::default() },
                                    eval_json,
                                    &UploadType::Simple(Media::new(eval_object))
                                ).await {
                                    Ok(_) => info!("Eval report uploaded"),
                                    Err(e) => warn!(error = %e, "Failed to upload eval report"),
                                }
                            }
                        }
                        Err(e) => warn!(error = %e, "Failed to parse eval response as JSON"),
                    }
                }
                Err(e) => warn!(error = %e, "Eval stage failed"),
            }
        }
    } else {
        info!("ANTHROPIC_API_KEY not set, skipping eval stage");
    }
```

- [ ] **Step 2: Run `cargo check`**

Run: `cd apps/daily-agent && cargo check`
Expected: Compiles without errors.

- [ ] **Step 3: Run `cargo clippy`**

Run: `cd apps/daily-agent && cargo clippy -- -D warnings`
Expected: No warnings.

- [ ] **Step 4: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: add eval stage with LLM judge scoring"
```

### Task 6: Run full Rust test suite

**Files:** None (verification only)

- [ ] **Step 1: Run all tests**

Run: `cd apps/daily-agent && cargo test`
Expected: All tests pass (existing + new prompt tests).

- [ ] **Step 2: Run clippy**

Run: `cd apps/daily-agent && cargo clippy -- -D warnings`
Expected: No warnings.

---

## Chunk 2: Swift — Mobile UI Changes

### Task 7: Add new fields to Swift Summary model

**Files:**
- Modify: `apps/mobile-swift/EngPulse/Models/Summary.swift:7-21`

- [ ] **Step 1: Add `promptVersion` and `evalScore` properties**

In `Summary.swift`, add after line 13 (`let selectedBy: String?`):

```swift
    let promptVersion: String?
    let evalScore: Double?
```

- [ ] **Step 2: Add CodingKeys for the new fields**

In the `CodingKeys` enum (line 15-21), add before the closing `}`:

```swift
        case promptVersion = "prompt_version"
        case evalScore = "eval_score"
```

- [ ] **Step 3: Add default values for backwards compatibility**

The struct needs an explicit init with defaults for the new fields so existing call sites (preview data) don't break. Add after the CodingKeys enum:

```swift
    init(date: String, url: String, title: String, summarySnippet: String?,
         originalUrl: String?, model: String?, selectedBy: String?,
         promptVersion: String? = nil, evalScore: Double? = nil) {
        self.date = date
        self.url = url
        self.title = title
        self.summarySnippet = summarySnippet
        self.originalUrl = originalUrl
        self.model = model
        self.selectedBy = selectedBy
        self.promptVersion = promptVersion
        self.evalScore = evalScore
    }
```

- [ ] **Step 4: Build to verify**

Run: `cd apps/mobile-swift && xcodebuild -project EngPulse.xcodeproj -scheme EngPulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add apps/mobile-swift/EngPulse/Models/Summary.swift
git commit -m "feat(swift): add promptVersion and evalScore to Summary model"
```

### Task 8: Add prompt version filter to SettingsView

**Files:**
- Modify: `apps/mobile-swift/EngPulse/Views/SettingsView.swift:17-28`

- [ ] **Step 1: Add AppStorage property**

In `SettingsView.swift`, add after line 12 (`@AppStorage("selectedModelFilter")`):

```swift
    @AppStorage("promptVersionFilter") private var promptVersionFilter: String = "production"
```

- [ ] **Step 2: Add prompt version picker section**

Add a new section after the Feed Filter section (after line 28):

```swift
                // Summary Format Section
                Section {
                    Picker("Format", selection: $promptVersionFilter) {
                        Text("Production").tag("production")
                        Text("Beta").tag("beta")
                        Text("Both").tag("both")
                    }
                } header: {
                    Text("Summary Format")
                } footer: {
                    Text("Compare production vs beta prompt formats.")
                }
```

- [ ] **Step 3: Add feedback tally section**

Add after the new Summary Format section:

```swift
                // Feedback Tally Section
                Section {
                    let tally = feedbackTally
                    HStack {
                        Label("Production", systemImage: "checkmark.circle")
                            .font(.subheadline)
                        Spacer()
                        Text("▲\(tally.v1Up)  ▼\(tally.v1Down)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Label("Beta", systemImage: "flask")
                            .font(.subheadline)
                        Spacer()
                        Text("▲\(tally.v2Up)  ▼\(tally.v2Down)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Feedback")
                }
```

- [ ] **Step 4: Add feedbackTally computed property**

Add before the `speechRateLabel` property (before line 135):

```swift
    private var feedbackTally: (v1Up: Int, v1Down: Int, v2Up: Int, v2Down: Int) {
        let allDefaults = UserDefaults.standard.dictionaryRepresentation()
        var result = (v1Up: 0, v1Down: 0, v2Up: 0, v2Down: 0)
        for (key, value) in allDefaults {
            guard key.hasPrefix("feedback_"), let rating = value as? String else { continue }
            let isBeta = key.contains("/beta/")
            switch (isBeta, rating) {
            case (false, "up"):   result.v1Up += 1
            case (false, "down"): result.v1Down += 1
            case (true, "up"):    result.v2Up += 1
            case (true, "down"):  result.v2Down += 1
            default: break
            }
        }
        return result
    }
```

- [ ] **Step 5: Build to verify**

Run: `cd apps/mobile-swift && xcodebuild -project EngPulse.xcodeproj -scheme EngPulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add apps/mobile-swift/EngPulse/Views/SettingsView.swift
git commit -m "feat(swift): add prompt version filter and feedback tally to settings"
```

### Task 9: Add prompt version filtering to HomeView

**Files:**
- Modify: `apps/mobile-swift/EngPulse/Views/HomeView.swift:28-51`

- [ ] **Step 1: Add AppStorage property**

In `HomeViewContent`, add after line 28 (`@AppStorage("selectedModelFilter")`):

```swift
    @AppStorage("promptVersionFilter") private var promptVersionFilter: String = "production"
```

- [ ] **Step 2: Add version filtering to filteredSummaries**

In the `filteredSummaries` computed property, add after the model filter block (after line 40) and before the search text filter:

```swift
        // Prompt version filter
        if promptVersionFilter == "production" {
            result = result.filter { $0.promptVersion == nil }
        } else if promptVersionFilter == "beta" {
            result = result.filter { $0.promptVersion == "v2" }
        }
        // "both" shows all
```

- [ ] **Step 3: Build to verify**

Run: `cd apps/mobile-swift && xcodebuild -project EngPulse.xcodeproj -scheme EngPulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add apps/mobile-swift/EngPulse/Views/HomeView.swift
git commit -m "feat(swift): filter summaries by prompt version"
```

### Task 10: Add eval score and feedback to DetailView

**Files:**
- Modify: `apps/mobile-swift/EngPulse/Views/DetailView.swift:131-162,208-240`

- [ ] **Step 1: Add eval score row to info sheet**

In `DetailView.swift`, in the `infoSheet` computed property, add after line 140 (the `selectedBy` LabeledContent):

```swift
                    if let score = summary.evalScore {
                        LabeledContent("Quality") {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                Text(String(format: "%.1f/5", max(score * 5, 1.0)))
                            }
                            .foregroundColor(.secondary)
                        }
                    }
```

- [ ] **Step 2: Add feedback buttons to toolbar**

In the toolbar `HStack` (line 211), add after the share button block (after line 237) but inside the HStack:

```swift
                    // Feedback
                    let feedbackKey = "feedback_\(summary.url)"
                    let currentFeedback = UserDefaults.standard.string(forKey: feedbackKey) ?? ""

                    Button {
                        UserDefaults.standard.set(currentFeedback == "up" ? "" : "up", forKey: feedbackKey)
                    } label: {
                        Image(systemName: currentFeedback == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.caption2)
                    }
                    .tint(currentFeedback == "up" ? .green : .secondary)

                    Button {
                        UserDefaults.standard.set(currentFeedback == "down" ? "" : "down", forKey: feedbackKey)
                    } label: {
                        Image(systemName: currentFeedback == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.caption2)
                    }
                    .tint(currentFeedback == "down" ? .red : .secondary)
```

Note: Using `UserDefaults` directly instead of `@AppStorage` because the key is dynamic (contains `summary.url`). The toolbar is rebuilt on interaction, so the UI updates.

- [ ] **Step 3: Build to verify**

Run: `cd apps/mobile-swift && xcodebuild -project EngPulse.xcodeproj -scheme EngPulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run Swift tests**

Run: `cd apps/mobile-swift && xcodebuild -project EngPulse.xcodeproj -scheme EngPulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | grep -E '(Test Suite|Tests|PASS|FAIL)'`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile-swift/EngPulse/Views/DetailView.swift
git commit -m "feat(swift): add eval score badge and feedback buttons to detail view"
```

---

## Chunk 3: Flutter — Mobile UI Changes

### Task 11: Add new fields to Flutter models

**Files:**
- Modify: `apps/mobile/lib/models/summary.dart:1-33`
- Modify: `apps/mobile/lib/models/cached_summary.dart:6-44`

- [ ] **Step 1: Add fields to Summary.fromJson**

In `summary.dart`, add to the `Summary` class after line 10 (`final String? selectedBy`):

```dart
  final String? promptVersion;
  final double? evalScore;
```

Add to the constructor (after `this.selectedBy`):

```dart
    this.promptVersion,
    this.evalScore,
```

Add to `fromJson` factory (after `selectedBy` line 30):

```dart
      promptVersion: json['prompt_version'] as String?,
      evalScore: (json['eval_score'] as num?)?.toDouble(),
```

- [ ] **Step 2: Add HiveFields to CachedSummary**

In `cached_summary.dart`, add after line 32 (`final String? selectedBy;`):

```dart
  @HiveField(9)
  final String? promptVersion;

  @HiveField(10)
  final double? evalScore;
```

Add to the constructor (after `this.selectedBy`):

```dart
    this.promptVersion,
    this.evalScore,
```

Add to `copyWith` method parameters and body.

- [ ] **Step 3: Regenerate Hive adapter**

Run: `cd apps/mobile && dart run build_runner build --delete-conflicting-outputs`
Expected: `cached_summary.g.dart` regenerated with fields 9 and 10.

- [ ] **Step 4: Run Flutter tests**

Run: `cd apps/mobile && flutter test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/models/summary.dart apps/mobile/lib/models/cached_summary.dart apps/mobile/lib/models/cached_summary.g.dart
git commit -m "feat(flutter): add promptVersion and evalScore to data models"
```

### Task 12: Add prompt version filter to Flutter settings and home screen

**Files:**
- Modify: `apps/mobile/lib/screens/settings_screen.dart:125-137`
- Modify: `apps/mobile/lib/screens/home_screen.dart:62-67`
- Modify: `apps/mobile/lib/services/user_service.dart`

- [ ] **Step 1: Add prompt version preference to UserService**

In `user_service.dart`, add methods for prompt version filter (use existing Hive prefs box):

```dart
  static String getPromptVersionFilter() {
    return _prefsBox?.get('promptVersionFilter', defaultValue: 'production') ?? 'production';
  }

  static Future<void> setPromptVersionFilter(String value) async {
    await _prefsBox?.put('promptVersionFilter', value);
  }
```

- [ ] **Step 2: Add filter to settings screen**

In `settings_screen.dart`, add a new section after the Reading section (after line 135):

```dart
          const SizedBox(height: 16),
          _buildSectionHeader(context, 'Summary Format'),
          _buildDropdownTile(
            context,
            title: 'Prompt Version',
            subtitle: 'Compare production vs beta formats',
            icon: Icons.science_rounded,
            value: UserService.getPromptVersionFilter(),
            items: const ['production', 'beta', 'both'],
            onChanged: (value) async {
              await UserService.setPromptVersionFilter(value);
              setState(() {});
            },
          ),
```

You will need to add the `_buildDropdownTile` helper method (similar to existing `_buildSliderTile`):

```dart
  Widget _buildDropdownTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required String value,
    required List<String> items,
    required ValueChanged<String> onChanged,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: Icon(icon, color: isDark ? AppTheme.primaryPurpleDark : AppTheme.primaryPurple),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        items: items.map((item) => DropdownMenuItem(
          value: item,
          child: Text(item[0].toUpperCase() + item.substring(1), style: const TextStyle(fontSize: 14)),
        )).toList(),
        onChanged: (v) { if (v != null) onChanged(v); },
      ),
    );
  }
```

- [ ] **Step 3: Add prompt version filtering to home screen**

In `home_screen.dart`, update `_filterByModel` (lines 62-67) to also filter by prompt version:

```dart
  List<CachedSummary> _filterByModel(List<CachedSummary> summaries) {
    var result = summaries;

    // Prompt version filter
    final versionFilter = UserService.getPromptVersionFilter();
    if (versionFilter == 'production') {
      result = result.where((s) => s.promptVersion == null).toList();
    } else if (versionFilter == 'beta') {
      result = result.where((s) => s.promptVersion == 'v2').toList();
    }

    // Model filter
    return result.where((s) {
      if (s.model == null) return true;
      return _selectedModel.matchesId(s.model);
    }).toList();
  }
```

- [ ] **Step 4: Run Flutter tests**

Run: `cd apps/mobile && flutter test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/services/user_service.dart apps/mobile/lib/screens/settings_screen.dart apps/mobile/lib/screens/home_screen.dart
git commit -m "feat(flutter): add prompt version filter to settings and home screen"
```

### Task 13: Add eval score to Flutter detail screen

**Files:**
- Modify: `apps/mobile/lib/screens/detail_screen.dart:308-328`

- [ ] **Step 1: Add eval score badge after the "Selected by" badge**

In `detail_screen.dart`, add after the `selectedBy` badge block (after line 328):

```dart
                      // Eval score badge
                      if (_currentSummary.evalScore != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: (isDark ? Colors.amber.shade300 : Colors.amber.shade700)
                                .withAlpha(25),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star_rounded, size: 12,
                                color: isDark ? Colors.amber.shade300 : Colors.amber.shade700),
                              const SizedBox(width: 3),
                              Text(
                                '${(_currentSummary.evalScore! * 5).clamp(1.0, 5.0).toStringAsFixed(1)}/5',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                                  color: isDark ? Colors.amber.shade300 : Colors.amber.shade700),
                              ),
                            ],
                          ),
                        ),
                      ],
```

- [ ] **Step 2: Run Flutter analyze**

Run: `cd apps/mobile && flutter analyze`
Expected: No issues found.

- [ ] **Step 3: Run Flutter tests**

Run: `cd apps/mobile && flutter test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/mobile/lib/screens/detail_screen.dart
git commit -m "feat(flutter): add eval score badge to detail screen"
```

---

## Chunk 4: Tests & Verification

### Task 14: Add Flutter model tests for new fields

**Files:**
- Modify: `apps/mobile/test/models/summary_test.dart`

- [ ] **Step 1: Add test for promptVersion and evalScore parsing**

Add to the `Summary fromJson` test group:

```dart
      test('parses promptVersion and evalScore', () {
        final json = {
          'date': '2025-01-15',
          'url': 'https://storage.example.com/test.md',
          'title': 'Test Title',
          'summary_snippet': 'Test snippet',
          'prompt_version': 'v2',
          'eval_score': 0.85,
        };

        final summary = Summary.fromJson(json);

        expect(summary.promptVersion, 'v2');
        expect(summary.evalScore, 0.85);
      });

      test('handles null promptVersion and evalScore', () {
        final json = {
          'date': '2025-01-15',
          'url': 'https://storage.example.com/test.md',
          'title': 'Test Title',
          'summary_snippet': 'Test snippet',
        };

        final summary = Summary.fromJson(json);

        expect(summary.promptVersion, isNull);
        expect(summary.evalScore, isNull);
      });
```

- [ ] **Step 2: Run tests**

Run: `cd apps/mobile && flutter test test/models/summary_test.dart`
Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add apps/mobile/test/models/summary_test.dart
git commit -m "test(flutter): add tests for promptVersion and evalScore fields"
```

### Task 15: Final verification

**Files:** None (verification only)

- [ ] **Step 1: Run full Rust test suite**

Run: `cd apps/daily-agent && cargo test && cargo clippy -- -D warnings`
Expected: All pass, no warnings.

- [ ] **Step 2: Run full Flutter test suite**

Run: `cd apps/mobile && flutter test && flutter analyze`
Expected: All pass, no issues.

- [ ] **Step 3: Build Swift app**

Run: `cd apps/mobile-swift && xcodebuild -project EngPulse.xcodeproj -scheme EngPulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test 2>&1 | grep -E '(Test Suite|Tests|BUILD|PASS|FAIL)'`
Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 4: Final commit (if any fixups needed)**

```bash
git add -A && git commit -m "fix: address verification issues"
```

- [ ] **Step 5: Create PR**

```bash
gh pr create --title "feat: prompt A/B testing with eval system" --body "$(cat <<'EOF'
## Summary
- Add parallel beta pipeline with persona-driven prompts (v2) alongside existing production prompts (v1)
- LLM judge (Claude) automatically scores all summaries on clarity, actionability, density, structure
- Mobile apps (Swift + Flutter) gain version filter, eval score display, and feedback buttons
- Beta failures never block production summaries

## Changes
- **daily-agent**: New `prompts.rs` module, 4-stage pipeline (fetch → prod → beta → eval)
- **manifest.json**: New `prompt_version` and `eval_score` fields (backwards compatible)
- **iOS app**: Settings filter, eval badge on info sheet, thumbs up/down feedback
- **Flutter app**: Same UI changes, reuses existing feedback widget

## Test plan
- [ ] Rust: `cargo test && cargo clippy`
- [ ] Flutter: `flutter test && flutter analyze`
- [ ] Swift: Xcode build + test
- [ ] Deploy daily-agent, verify both v1 and v2 summaries appear in manifest
- [ ] iOS app: toggle between Production/Beta/Both in Settings
- [ ] Verify eval scores appear on detail view info sheet

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
