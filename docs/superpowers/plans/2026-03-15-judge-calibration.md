# Judge Calibration Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Inject user feedback as few-shot calibration context into the eval judge prompt, run dual scoring, and disable OpenAI as a provider.

**Architecture:** The daily-agent's eval stage is extended to: (1) load recent feedback from `feedback/{date}.json` in GCS, (2) download rated summary content, (3) build a calibration prompt section, (4) run the eval twice (uncalibrated + calibrated), (5) store both results and use the calibrated score in the manifest.

**Tech Stack:** Rust, google-cloud-storage, serde_json, chrono

---

## File Structure

### Modified Files
- `apps/daily-agent/src/main.rs` — disable OpenAI, add feedback loading, calibration prompt building, dual eval, calibrated eval upload
- `apps/daily-agent/src/prompts.rs` — no changes needed (OpenAI is not referenced here)

### No New Files
All changes are in `main.rs`. The file is ~567 lines currently; these additions add ~150 lines of focused calibration logic.

---

## Chunk 1: Disable OpenAI

### Task 1: Remove OpenAI from provider list

**Files:**
- Modify: `apps/daily-agent/src/main.rs:101-132`

- [ ] **Step 1: Update `get_enabled_providers()` to exclude OpenAI**

At line 102, change:
```rust
let providers = [LlmProvider::Claude, LlmProvider::Gemini, LlmProvider::OpenAI];
```
To:
```rust
let providers = [LlmProvider::Claude, LlmProvider::Gemini];
```

- [ ] **Step 2: Update error message**

At line 130, change:
```rust
error!("No LLM providers configured. Set at least one of: GEMINI_API_KEY, OPENAI_API_KEY, ANTHROPIC_API_KEY");
```
To:
```rust
error!("No LLM providers configured. Set at least one of: GEMINI_API_KEY, ANTHROPIC_API_KEY");
```

- [ ] **Step 3: Verify it compiles**

```bash
cd apps/daily-agent && cargo check
```

- [ ] **Step 4: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: disable OpenAI provider, only Gemini and Claude"
```

---

## Chunk 2: Feedback Loading

### Task 2: Add feedback data structures and loading logic

**Files:**
- Modify: `apps/daily-agent/src/main.rs` — add structs and function after the existing struct definitions (~line 97)

- [ ] **Step 1: Add feedback structs and constants**

After the existing `EvalCriteria` struct (line 97), add:

```rust
/// Feedback entry from feedback/{date}.json
#[derive(Deserialize, Debug, Clone)]
struct FeedbackEntry {
    summary_url: String,
    feedback: String, // "up" or "down"
    #[allow(dead_code)]
    prompt_version: Option<String>,
    #[allow(dead_code)]
    uid: String,
    #[allow(dead_code)]
    timestamp: String,
}

/// Minimum feedback entries required to activate calibration
const CALIBRATION_MIN_RATINGS: usize = 5;
/// Maximum calendar days to scan backwards for feedback
const CALIBRATION_LOOKBACK_DAYS: i64 = 30;
/// Maximum words to include per anchor excerpt
const CALIBRATION_EXCERPT_WORDS: usize = 200;
```

- [ ] **Step 2: Add feedback loading function**

After the constants, add:

```rust
/// Load recent feedback from GCS, scanning backwards up to CALIBRATION_LOOKBACK_DAYS.
/// Returns all collected feedback entries (most recent first).
async fn load_recent_feedback(
    gcs_client: &Client,
    bucket_name: &str,
) -> Vec<FeedbackEntry> {
    let mut all_feedback = Vec::new();
    let today = Utc::now().date_naive();

    for days_back in 0..CALIBRATION_LOOKBACK_DAYS {
        let date = today - chrono::Duration::days(days_back);
        let object = format!("feedback/{}.json", date.format("%Y-%m-%d"));

        match gcs_client.download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object,
                ..Default::default()
            },
            &Range::default(),
        ).await {
            Ok(data) => {
                if let Ok(entries) = serde_json::from_slice::<Vec<FeedbackEntry>>(&data) {
                    all_feedback.extend(entries);
                }
            }
            Err(_) => {} // File doesn't exist for this date, skip
        }
    }

    all_feedback
}
```

- [ ] **Step 3: Add polarity check helper**

```rust
/// Check if feedback has both polarities (at least 1 up and 1 down).
fn has_both_polarities(feedback: &[FeedbackEntry]) -> bool {
    let has_up = feedback.iter().any(|f| f.feedback == "up");
    let has_down = feedback.iter().any(|f| f.feedback == "down");
    has_up && has_down
}
```

- [ ] **Step 4: Add excerpt helper**

```rust
/// Truncate content to approximately N words.
fn excerpt(content: &str, max_words: usize) -> String {
    content
        .split_whitespace()
        .take(max_words)
        .collect::<Vec<_>>()
        .join(" ")
}
```

- [ ] **Step 5: Write tests for helpers**

At the bottom of main.rs, inside the existing `#[cfg(test)]` block (or create one if not present — check if there's already a tests module):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_has_both_polarities_true() {
        let feedback = vec![
            FeedbackEntry {
                summary_url: "a".into(), feedback: "up".into(),
                prompt_version: None, uid: "u".into(), timestamp: "t".into(),
            },
            FeedbackEntry {
                summary_url: "b".into(), feedback: "down".into(),
                prompt_version: None, uid: "u".into(), timestamp: "t".into(),
            },
        ];
        assert!(has_both_polarities(&feedback));
    }

    #[test]
    fn test_has_both_polarities_false_all_up() {
        let feedback = vec![
            FeedbackEntry {
                summary_url: "a".into(), feedback: "up".into(),
                prompt_version: None, uid: "u".into(), timestamp: "t".into(),
            },
        ];
        assert!(!has_both_polarities(&feedback));
    }

    #[test]
    fn test_excerpt_truncates() {
        let content = "one two three four five six seven eight nine ten";
        assert_eq!(excerpt(content, 5), "one two three four five");
    }

    #[test]
    fn test_excerpt_short_content() {
        let content = "short";
        assert_eq!(excerpt(content, 100), "short");
    }
}
```

- [ ] **Step 6: Run tests**

```bash
cd apps/daily-agent && cargo test
```

Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: add feedback loading and calibration helpers"
```

---

## Chunk 3: Calibration Prompt Building

### Task 3: Build calibration context from feedback

**Files:**
- Modify: `apps/daily-agent/src/main.rs` — add function after the helpers from Task 2

- [ ] **Step 1: Add calibration context builder**

```rust
/// Build calibration prompt section from user feedback.
/// Downloads rated summaries from GCS and formats as few-shot context.
/// Returns None if insufficient feedback or missing polarity.
async fn build_calibration_context(
    feedback: &[FeedbackEntry],
    gcs_client: &Client,
    bucket_name: &str,
    manifest: &[ManifestEntry],
) -> Option<String> {
    if feedback.len() < CALIBRATION_MIN_RATINGS || !has_both_polarities(feedback) {
        return None;
    }

    // Collect up to 2 most recent "up" and 2 most recent "down"
    let ups: Vec<_> = feedback.iter().filter(|f| f.feedback == "up").take(2).collect();
    let downs: Vec<_> = feedback.iter().filter(|f| f.feedback == "down").take(2).collect();

    let url_prefix = format!("https://storage.googleapis.com/{}/", bucket_name);

    let mut context = String::from("## User Calibration\n\nThe user rated these summaries highly:\n");

    for entry in &ups {
        let object_path = entry.summary_url.replace(&url_prefix, "");
        let title = manifest.iter()
            .find(|m| m.url == entry.summary_url)
            .map(|m| m.title.as_str())
            .unwrap_or("Unknown article");

        match gcs_client.download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object: object_path,
                ..Default::default()
            },
            &Range::default(),
        ).await {
            Ok(data) => {
                if let Ok(content) = String::from_utf8(data) {
                    context.push_str(&format!(
                        "\n[Title: \"{}\"]\n{}\n",
                        title,
                        excerpt(&content, CALIBRATION_EXCERPT_WORDS)
                    ));
                }
            }
            Err(e) => {
                warn!(url = %entry.summary_url, error = %e, "Failed to download rated summary for calibration");
            }
        }
    }

    context.push_str("\nThe user rated these summaries poorly:\n");

    for entry in &downs {
        let object_path = entry.summary_url.replace(&url_prefix, "");
        let title = manifest.iter()
            .find(|m| m.url == entry.summary_url)
            .map(|m| m.title.as_str())
            .unwrap_or("Unknown article");

        match gcs_client.download_object(
            &GetObjectRequest {
                bucket: bucket_name.to_string(),
                object: object_path,
                ..Default::default()
            },
            &Range::default(),
        ).await {
            Ok(data) => {
                if let Ok(content) = String::from_utf8(data) {
                    context.push_str(&format!(
                        "\n[Title: \"{}\"]\n{}\n",
                        title,
                        excerpt(&content, CALIBRATION_EXCERPT_WORDS)
                    ));
                }
            }
            Err(e) => {
                warn!(url = %entry.summary_url, error = %e, "Failed to download rated summary for calibration");
            }
        }
    }

    context.push_str("\nUse these as reference points when scoring. Align your quality assessment with the user's demonstrated preferences.\n");

    Some(context)
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd apps/daily-agent && cargo check
```

- [ ] **Step 3: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: add calibration context builder from user feedback"
```

---

## Chunk 4: Dual Eval and Manifest Update

### Task 4: Integrate calibration into the eval stage

**Files:**
- Modify: `apps/daily-agent/src/main.rs:442-547` — the eval stage

- [ ] **Step 1: Add feedback loading call before the eval stage**

Before line 442 (`// --- Stage 4: Eval ---`), add:

```rust
    // --- Load user feedback for calibration ---
    let feedback = load_recent_feedback(&gcs_client, &bucket_name).await;
    info!(feedback_count = feedback.len(), "Loaded recent user feedback");

    // Build calibration context (None if insufficient data)
    let calibration_context = build_calibration_context(
        &feedback, &gcs_client, &bucket_name, &manifest
    ).await;

    if calibration_context.is_some() {
        info!("Calibration context built, dual eval will run");
    } else {
        info!("Insufficient feedback for calibration, running standard eval only");
    }
```

- [ ] **Step 2: Extract eval into a reusable closure**

The current eval logic (lines 473-543) runs once. We need it to run twice (uncalibrated + calibrated). Refactor the eval prompt construction and LLM call into a pattern that can be reused.

Inside the existing `if !eval_summaries.is_empty()` block, replace the single eval call with:

```rust
        if !eval_summaries.is_empty() {
            let base_eval_prompt = format!(
                "You are evaluating article summaries for quality. Score each summary on these criteria (1-5):\n\n\
                1. Clarity: How easy is it to scan and understand on a mobile phone?\n\
                2. Actionability: Does it provide concrete takeaways the reader can act on this week?\n\
                3. Information density: What is the signal-to-noise ratio? Is every sentence valuable?\n\
                4. Structure: Is it well-formatted with clear sections, bold key phrases, scannable bullets?\n\n\
                The reader is a senior engineering leader. They have 2-3 minutes on their phone.\n\n\
                For each summary below, return ONLY a JSON object (no markdown fences):\n\
                {{\"scores\": [{{\"summary_id\": \"id\", \"clarity\": N, \"actionability\": N, \"information_density\": N, \"structure\": N, \"reasoning\": \"...\"}}]}}\n\n"
            );

            let mut summaries_text = String::new();
            for (id, content) in &eval_summaries {
                summaries_text.push_str(&format!("--- Summary: {} ---\n{}\n\n", id, content));
            }

            // --- Pass 1: Uncalibrated eval (always runs) ---
            let uncalibrated_prompt = format!("{}{}", base_eval_prompt, summaries_text);
            let uncalibrated_result = run_eval_pass(
                &http_client, claude_key, &uncalibrated_prompt,
                &gcs_client, &bucket_name, &today, "eval",
            ).await;

            // Apply uncalibrated scores to manifest entries
            if let Some(ref scores) = uncalibrated_result {
                apply_eval_scores(scores, &mut new_manifest_entries);
            }

            // --- Pass 2: Calibrated eval (only if calibration context available) ---
            if let Some(ref cal_context) = calibration_context {
                let calibrated_prompt = format!("{}\n{}{}", cal_context, base_eval_prompt, summaries_text);
                let calibrated_result = run_eval_pass(
                    &http_client, claude_key, &calibrated_prompt,
                    &gcs_client, &bucket_name, &today, "eval-calibrated",
                ).await;

                // Override manifest scores with calibrated scores
                if let Some(ref scores) = calibrated_result {
                    apply_eval_scores(scores, &mut new_manifest_entries);

                    // Log agreement with user feedback
                    log_calibration_agreement(&feedback, scores, &new_manifest_entries);
                }
            }
        }
```

- [ ] **Step 3: Add `run_eval_pass` helper function**

Add this function before `main()`:

```rust
/// Run a single eval pass: send prompt to Claude, parse response, upload report.
/// Returns parsed scores JSON on success.
async fn run_eval_pass(
    http_client: &reqwest::Client,
    claude_key: &str,
    prompt: &str,
    gcs_client: &Client,
    bucket_name: &str,
    today: &str,
    report_prefix: &str,  // "eval" or "eval-calibrated"
) -> Option<serde_json::Value> {
    match call_llm_with_retry(http_client, LlmProvider::Claude, claude_key, prompt.to_string()).await {
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
                            &UploadType::Simple(Media::new(eval_object.clone()))
                        ).await {
                            Ok(_) => info!(report = %eval_object, "Eval report uploaded"),
                            Err(e) => warn!(error = %e, report = %eval_object, "Failed to upload eval report"),
                        }
                    }
                    Some(json)
                }
                Err(e) => {
                    warn!(error = %e, pass = %report_prefix, "Failed to parse eval response as JSON");
                    None
                }
            }
        }
        Err(e) => {
            warn!(error = %e, pass = %report_prefix, "Eval pass failed");
            None
        }
    }
}
```

- [ ] **Step 4: Add `apply_eval_scores` helper function**

```rust
/// Apply eval scores from parsed JSON to manifest entries.
fn apply_eval_scores(json: &serde_json::Value, entries: &mut Vec<ManifestEntry>) {
    if let Some(scores) = json.get("scores").and_then(|s| s.as_array()) {
        for score in scores {
            let summary_id = score.get("summary_id").and_then(|s| s.as_str()).unwrap_or("");
            let clarity = score.get("clarity").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as f64;
            let actionability = score.get("actionability").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as f64;
            let info_density = score.get("information_density").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as f64;
            let structure_score = score.get("structure").and_then(|v| v.as_u64()).unwrap_or(EVAL_DEFAULT_SCORE) as f64;
            let total = (clarity + actionability + info_density + structure_score) / EVAL_MAX_TOTAL;
            let reasoning = score.get("reasoning").and_then(|s| s.as_str()).unwrap_or("");

            info!(summary_id = %summary_id, total = %total, reasoning = %reasoning, "Eval score");

            for entry in entries.iter_mut() {
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
}
```

- [ ] **Step 5: Add `log_calibration_agreement` helper**

```rust
/// Log how well calibrated scores agree with user feedback.
fn log_calibration_agreement(
    feedback: &[FeedbackEntry],
    calibrated_json: &serde_json::Value,
    entries: &[ManifestEntry],
) {
    let scores = match calibrated_json.get("scores").and_then(|s| s.as_array()) {
        Some(s) => s,
        None => return,
    };

    let mut agree = 0;
    let mut total = 0;

    for fb in feedback {
        // Find the manifest entry for this feedback
        if let Some(entry) = entries.iter().find(|e| e.url == fb.summary_url) {
            if let Some(eval_score) = entry.eval_score {
                total += 1;
                // "up" should correlate with higher scores (>0.6), "down" with lower (<0.6)
                let agrees = (fb.feedback == "up" && eval_score > 0.6)
                    || (fb.feedback == "down" && eval_score <= 0.6);
                if agrees {
                    agree += 1;
                }
            }
        }
    }

    if total > 0 {
        info!(
            agreement = %format!("{}/{}", agree, total),
            pct = %format!("{:.0}%", (agree as f64 / total as f64) * 100.0),
            "Calibration agreement with user feedback"
        );
    }
}
```

- [ ] **Step 6: Verify it compiles**

```bash
cd apps/daily-agent && cargo check
```

- [ ] **Step 7: Run all tests**

```bash
cd apps/daily-agent && cargo test
```

Expected: All tests pass (existing + new).

- [ ] **Step 8: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat: dual eval with user feedback calibration"
```

---

## Chunk 5: Verification

### Task 5: Local dry-run verification

- [ ] **Step 1: Run clippy**

```bash
cd apps/daily-agent && cargo clippy -- -D warnings
```

Expected: No warnings.

- [ ] **Step 2: Run full test suite**

```bash
cd apps/daily-agent && cargo test --verbose
```

Expected: All tests pass.

- [ ] **Step 3: Commit any clippy fixes**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "fix: address clippy warnings"
```

Only if there were fixes needed.

### Task 6: CI verification

- [ ] **Step 1: Push branch and create PR**

```bash
git push -u origin feat/judge-calibration
gh pr create --title "feat: judge calibration with user feedback" --body "..."
```

- [ ] **Step 2: Verify all CI checks pass**

```bash
gh pr checks <PR_NUMBER> --watch
```

All 4 checks (rust, python, flutter, swift) should pass.
