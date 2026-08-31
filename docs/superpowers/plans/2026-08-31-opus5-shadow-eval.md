# Opus 5 Shadow-Eval Lane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate a shadow V3 Insight Brief with `claude-opus-5` alongside the prod `claude-opus-4-8` brief every day, score both with the same judge in the same eval call, and promote Opus 5 only after it wins or ties for 5 consecutive days.

**Architecture:** The shadow lane lives entirely inside the existing daily-agent Cloud Run job — no new infrastructure. When `SHADOW_MODEL` is set, Stage 3 generates a second V3 brief via `LlmOptions.model` (landed in #162), uploads it to `summaries/v3-shadow/{date}.json` (never added to `manifest.json`, so apps and users never see it), and appends it to the `v3_summaries` list that the existing `eval-v3` judge pass already scores — prod and shadow are judged side-by-side in one call. A report script reads the last N `eval-v3/{date}.json` reports and prints the comparison.

**Tech Stack:** Rust (daily-agent, llm-client), GCS JSON artifacts, existing Gemini-as-judge eval, bash+python3 report script.

**Spec:** Agreed in-session 2026-08-31 (this plan's Design Notes double as the spec).

## Global Constraints

- Rust toolchain 1.83+; `cargo clippy -- -D warnings` must stay clean (CI enforces).
- TDD: every behavior change lands with a test written and observed failing first.
- Shadow output must NEVER appear in `manifest.json` — clients must be unaffected.
- Claude requests never send `temperature` (Opus 4.7+ rejects it; existing `build_claude_request` already omits it — do not add it).
- Model IDs: prod `claude-opus-4-8`, shadow `claude-opus-5` (exact strings).
- Per Anton's memory: model bumps are API contract changes — final verification is a real job run, not just tests.

## Design Notes (spec)

1. **Where evals run:** inside the existing daily 06:00 UTC Cloud Run job (`se-daily-agent-job`), where the `eval-v3` judge pass already runs with Gemini as judge (avoids Claude-judging-Claude self-preference). Cost: one extra Opus 5 call/day (~$0.10–0.20 incl. thinking tokens); zero extra judge calls (joint pass).
2. **Opus 5 API delta this plan must absorb:** on Opus 5, omitting `thinking` runs *adaptive thinking* — responses can begin with thinking blocks whose `text` is absent. `call_claude` currently reads `content.first().text` and would fail. Fix: return the first block that has text.
3. **Promotion gate:** shadow avg score ≥ prod avg score in `eval-v3/{date}.json` for 5 consecutive days → flip `DEFAULT_CLAUDE_MODEL` to `claude-opus-5`, remove `SHADOW_MODEL`, verify with a real run (separate PR, out of scope here).
4. **Config:** `SHADOW_MODEL` env var on the job, wired in `deploy.yml` so redeploys preserve it. Unset ⇒ lane fully off (today's behavior).
5. **Judge report shape:** `eval-v3/{date}.json` already stores `{"scores": [{"summary_id", key_idea_clarity, why_it_matters_relevance, deep_dive_depth, action_quality, "reasoning"}]}`. Prod id stays `v3-claude`; shadow id is `v3-shadow`. `apply_eval_scores` matches manifest entries by id, so `v3-shadow` is naturally ignored for the manifest.
6. **Follow-up note (2026-08-31):** judge scores are currently saturated (prod flat 5.0 across all four criteria), so before acting on the 5-day promotion gate in Note 3, the judge prompt should first be amended to emit an explicit pairwise winner between prod and shadow for the same day (e.g. `"pairwise_winner": "v3-claude" | "v3-shadow" | "tie"`) — comparing two scores both pinned at the ceiling isn't a real signal. Separately, staleness alerting is already delivered by the live "No Summary Generated (25h)" Cloud Monitoring policy (`conditionMonitoringQueryLanguage`, MQL `absent_for 90000s`, see `scripts/setup-monitoring.sh`); do not re-add `conditionAbsent`-based staleness variants — Cloud Monitoring rejects `conditionAbsent` durations beyond ~24h at policy-creation time, which is why the MQL form is used instead.

---

### Task 1: llm-client — tolerate leading non-text content blocks (Opus 5 thinking)

**Files:**
- Modify: `libs/llm-client/src/lib.rs` (ClaudeResponse text extraction in `call_claude`, tests module)

**Interfaces:**
- Consumes: `ClaudeContentBlock { text: Option<String> }`, `ClaudeResponse` (private structs, tests live in-module)
- Produces: `call_claude` returns the first content block that carries text; behavior covered via new helper `first_text_block(content: &[ClaudeContentBlock]) -> Option<&str>` used by `call_claude`.

- [ ] **Step 1: Write the failing tests** (in `mod tests`, after `test_claude_response_parses_usage`)

```rust
#[test]
fn test_first_text_block_skips_leading_thinking_block() {
    // Opus 5 adaptive thinking: first block can be a thinking block with no text.
    let blocks = vec![
        ClaudeContentBlock { text: None },
        ClaudeContentBlock { text: Some("answer".to_string()) },
    ];
    assert_eq!(first_text_block(&blocks), Some("answer"));
}

#[test]
fn test_first_text_block_none_when_no_text() {
    let blocks = vec![ClaudeContentBlock { text: None }];
    assert_eq!(first_text_block(&blocks), None);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd libs/llm-client && cargo test first_text_block`
Expected: FAIL — `cannot find function first_text_block`

- [ ] **Step 3: Minimal implementation** (above `call_claude`)

```rust
fn first_text_block(content: &[ClaudeContentBlock]) -> Option<&str> {
    content.iter().find_map(|b| b.text.as_deref())
}
```

And in `call_claude`, replace the `if let Some(content) = resp.content { if let Some(block) = content.first() { ... } }` extraction with:

```rust
    if let Some(content) = resp.content {
        if let Some(text) = first_text_block(&content) {
            return Ok(text.to_string());
        }
    }

    Err("No content returned from Claude".into())
```

- [ ] **Step 4: Verify green**

Run: `cd libs/llm-client && cargo test && cargo clippy -- -D warnings`
Expected: all pass (38 existing + 2 new), clippy clean

- [ ] **Step 5: Commit**

```bash
git add libs/llm-client/src/lib.rs
git commit -m "fix(llm-client): read first text block, not first block (Opus 5 thinking)"
```

### Task 2: daily-agent — shadow V3 generation + joint eval

**Files:**
- Modify: `apps/daily-agent/src/main.rs` (Stage 3 block at ~line 607-673; the `v3_summaries` construction before the eval pass at ~line 739)

**Interfaces:**
- Consumes: `LlmOptions { model: Option<String>, .. }` (#162); `v3_config.summary_prompt(source, title, text) -> String`; `v3_summaries: Vec<(String, String)>` fed to `run_eval_pass(.., "eval-v3")`
- Produces: env reader `shadow_model() -> Option<String>`; const `SHADOW_SUMMARY_ID: &str = "v3-shadow"`; GCS object `summaries/v3-shadow/{date}.json`

- [ ] **Step 1: Write the failing test** (daily-agent `mod tests`)

```rust
#[test]
fn test_shadow_model_reads_env() {
    // Pure precedence check via the helper's inner fn.
    assert_eq!(shadow_model_from(Some("claude-opus-5".to_string())), Some("claude-opus-5".to_string()));
    assert_eq!(shadow_model_from(Some(String::new())), None); // empty = off
    assert_eq!(shadow_model_from(None), None);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd apps/daily-agent && cargo test shadow_model`
Expected: FAIL — `cannot find function shadow_model_from`

- [ ] **Step 3: Minimal implementation** (near other consts/helpers in main.rs)

```rust
const SHADOW_SUMMARY_ID: &str = "v3-shadow";

/// Empty or unset SHADOW_MODEL disables the shadow lane.
fn shadow_model_from(env_val: Option<String>) -> Option<String> {
    env_val.filter(|m| !m.is_empty())
}

fn shadow_model() -> Option<String> {
    shadow_model_from(std::env::var("SHADOW_MODEL").ok())
}
```

- [ ] **Step 4: Verify green, then wire Stage 3**

Run: `cd apps/daily-agent && cargo test shadow_model` → PASS.

Then, inside the existing `if let Some((_, claude_key)) = claude_entry { ... }` block, AFTER the prod V3 match closes (after line ~670, still inside the `claude_entry` block), add — and also capture the prod V3 JSON for eval reuse (the existing code already pushes `("v3-claude", clean_json)` to `v3_summaries`; keep that untouched):

```rust
        // Shadow lane: same prompt, candidate model; never enters the manifest.
        if let Some(shadow) = shadow_model() {
            let shadow_prompt = v3_config.summary_prompt(&best_article.source, &best_article.title, &truncated_text);
            let shadow_options = LlmOptions { model: Some(shadow.clone()), ..Default::default() };

            match call_llm(&http_client, LlmProvider::Claude, claude_key, shadow_prompt, &shadow_options).await {
                Ok(response) => {
                    let json_str = response.trim();
                    let clean_json = if let (Some(start), Some(end)) = (json_str.find('{'), json_str.rfind('}')) {
                        json_str[start..=end].to_string()
                    } else {
                        json_str.to_string()
                    };

                    match serde_json::from_str::<serde_json::Value>(&clean_json) {
                        Ok(parsed) if parsed.get("key_idea").is_some() && parsed.get("deep_dive").is_some() => {
                            let object_path = format!("summaries/v3-shadow/{}.json", today);
                            match gcs_client.upload_object(
                                &UploadObjectRequest { bucket: bucket_name.clone(), ..Default::default() },
                                clean_json.as_bytes().to_vec(),
                                &UploadType::Simple(Media::new(object_path.clone())),
                            ).await {
                                Ok(_) => {
                                    info!(model = %shadow, "Shadow V3 brief uploaded to {}", object_path);
                                    shadow_v3_json = Some(clean_json);
                                }
                                Err(e) => warn!(error = %e, "Failed to upload shadow V3 brief"),
                            }
                        }
                        _ => warn!(model = %shadow, "Shadow V3 response invalid, skipping"),
                    }
                }
                Err(e) => warn!(model = %shadow, error = %e, "Shadow V3 generation failed"),
            }
        }
```

Declare `let mut shadow_v3_json: Option<String> = None;` just before the Stage 3 block.

**Do NOT push the shadow into `eval_summaries`** — the partition at main.rs:710 buckets ids by manifest lookup, and the shadow has no manifest entry, so it would land in `v1_summaries` (wrong rubric). Instead, in the V3 eval block (main.rs:739-753):

1. Change the gate to include the shadow:

```rust
        if !v3_summaries.is_empty() || shadow_v3_json.is_some() {
```

2. After the `for (id, content) in &v3_summaries { ... }` section-building loop, append:

```rust
            if let Some(json) = &shadow_v3_json {
                section.push_str(&format!("--- Summary: {} ---\n{}\n\n", SHADOW_SUMMARY_ID, json));
            }
```

`apply_eval_scores` matches by manifest `summary_id`, so the `v3-shadow` score stays report-only — exactly what we want.

- [ ] **Step 5: Verify green + clippy**

Run: `cd apps/daily-agent && cargo test && cargo clippy -- -D warnings`
Expected: 67 existing + 1 new pass, clippy clean

- [ ] **Step 6: Commit**

```bash
git add apps/daily-agent/src/main.rs
git commit -m "feat(daily-agent): SHADOW_MODEL lane — shadow V3 brief judged alongside prod"
```

### Task 3: comparison report script

**Files:**
- Create: `scripts/shadow-eval-report.sh` (executable)

**Interfaces:**
- Consumes: public GCS objects `eval-v3/{date}.json` with `{"scores": [{"summary_id", ...four criteria..., "reasoning"}]}`
- Produces: stdout table: date, prod avg, shadow avg, winner; exit 0

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Compare prod vs shadow V3 eval scores over the last N days (default 7).
set -euo pipefail
DAYS="${1:-7}"
BUCKET="${GCS_BUCKET:-tsvet01-agent-brain}"

for i in $(seq 0 $((DAYS - 1))); do
  DATE=$(date -u -v-"${i}"d +%F 2>/dev/null || date -u -d "-${i} days" +%F)
  curl -sf "https://storage.googleapis.com/${BUCKET}/eval-v3/${DATE}.json" | python3 -c "
import json, sys
r = json.load(sys.stdin)
scores = {s['summary_id']: (s['key_idea_clarity'] + s['why_it_matters_relevance'] + s['deep_dive_depth'] + s['action_quality']) / 4
          for s in r.get('scores', [])}
prod, shadow = scores.get('v3-claude'), scores.get('v3-shadow')
verdict = '-' if shadow is None else ('SHADOW' if shadow > prod else ('tie' if shadow == prod else 'prod'))
print(f\"${DATE}  prod={prod}  shadow={shadow}  winner={verdict}\")
" || echo "${DATE}  (no eval report)"
done
```

- [ ] **Step 2: Verify against live data**

Run: `chmod +x scripts/shadow-eval-report.sh && ./scripts/shadow-eval-report.sh 3`
Expected: three lines; today/yesterday rows show `prod=<n> shadow=None winner=-` (shadow not deployed yet), missing days show `(no eval report)`.

- [ ] **Step 3: Commit**

```bash
git add scripts/shadow-eval-report.sh
git commit -m "feat(scripts): shadow-eval comparison report"
```

### Task 4: deploy wiring + real-run verification

**Files:**
- Modify: `.github/workflows/deploy.yml` (daily-agent `gcloud run jobs deploy` step)

**Interfaces:**
- Produces: `SHADOW_MODEL=claude-opus-5` env on `se-daily-agent-job`, durable across deploys

- [ ] **Step 1: Add the env var to the job deploy flags**

In the `deploy-agents` job's daily-agent `gcloud run jobs deploy` command, alongside the existing `--set-secrets` flags, add:

```yaml
          --set-env-vars=SHADOW_MODEL=claude-opus-5 \
```

- [ ] **Step 2: Commit and open PR**

```bash
git add .github/workflows/deploy.yml
git commit -m "deploy: enable Opus 5 shadow lane on daily-agent job"
git push -u origin shadow-eval
gh pr create --title "Opus 5 shadow-eval lane + staleness alert" --body "Daily shadow V3 brief with claude-opus-5 judged alongside prod claude-opus-4-8 in the existing eval-v3 pass; scripts/shadow-eval-report.sh compares scores; promotion after 5 winning/tied days. Also adds a 26h staleness alert that stays open until a successful run (the failure alert auto-resolves in 5 minutes). Shadow output never enters manifest.json."
```

- [ ] **Step 3: After merge+deploy — real-run verification (per model-bump memory)**

```bash
gcloud run jobs execute se-daily-agent-job --region us-central1 --project tsvet01 --wait
curl -s "https://storage.googleapis.com/tsvet01-agent-brain/summaries/v3-shadow/$(date -u +%F).json" | head -c 300
./scripts/shadow-eval-report.sh 1
```

Expected: shadow JSON exists with `key_idea`; report shows both scores. Also verify `manifest.json` gained NO `v3-shadow` entry, and check the `LLM usage` log lines show the `claude-opus-5` call with plausible token counts.

- [ ] **Step 4: Watch 5 days**

Run `./scripts/shadow-eval-report.sh 5` daily (or after 5 days). Promotion decision when shadow ≥ prod for 5 consecutive days.

### Task 5: staleness alert that stays open until actually fixed

**Context:** The existing failure alerts (`setup-monitoring.sh`) threshold on `completed_execution_count{result="failed"}` over a 300s window with `duration: 0s` — the incident auto-closes ~5 minutes after firing even when the system is still broken (observed 2026-08-31: fired 06:05, "resolved" minutes later, while the day's summary was missing until the manual re-run). Keep the failure alerts as immediate FYI; add an absence alert as the state signal.

**Files:**
- Modify: `scripts/setup-monitoring.sh` (append a third policy, same pattern as the existing two)

**Interfaces:**
- Produces: Cloud Monitoring policy "Eng Pulse: no successful daily run in 26h" using `conditionAbsent` on `result="succeeded"`; opens 26h after the last success, closes only when a run succeeds.

- [ ] **Step 1: Add the policy JSON to setup-monitoring.sh** (same create-from-file pattern and notification channel as the existing policies)

```json
{
  "displayName": "Eng Pulse: no successful daily run in 26h",
  "documentation": {
    "content": "se-daily-agent-job has not completed successfully in 26h — the daily summary is missing or stale. Re-run: gcloud run jobs execute se-daily-agent-job --region us-central1 (use --args=--date,YYYY-MM-DD to backfill an older day). This alert stays open until a run succeeds.",
    "mimeType": "text/markdown"
  },
  "conditions": [
    {
      "displayName": "No successful execution in 26h",
      "conditionAbsent": {
        "filter": "resource.type=\"cloud_run_job\" AND resource.labels.job_name=\"se-daily-agent-job\" AND metric.type=\"run.googleapis.com/job/completed_execution_count\" AND metric.labels.result=\"succeeded\"",
        "aggregations": [
          { "alignmentPeriod": "3600s", "perSeriesAligner": "ALIGN_SUM" }
        ],
        "duration": "93600s",
        "trigger": { "count": 1 }
      }
    }
  ],
  "combiner": "OR",
  "enabled": true,
  "alertStrategy": { "autoClose": "604800s" }
}
```

- [ ] **Step 2: Create the policy in GCP** (one-off; the script edit keeps it reproducible)

Run the script's create command for just this policy (reusing the channel ID the script looks up), or apply via `gcloud alpha monitoring policies create --policy-from-file=<tmpfile>`.
Verify: `gcloud alpha monitoring policies list --format="value(displayName)"` includes the new policy.

- [ ] **Step 3: Commit**

```bash
git add scripts/setup-monitoring.sh
git commit -m "feat(monitoring): 26h staleness alert — stays open until a run succeeds"
```
