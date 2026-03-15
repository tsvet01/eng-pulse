# Judge Calibration with User Feedback

## Problem

The automated eval judge (Claude) scores summaries based on generic quality criteria. These scores may not align with the user's actual preferences. User feedback (thumbs up/down) is collected but not used to improve scoring.

## Goals

1. Load recent user feedback and inject it as few-shot context into the eval prompt
2. Run dual scoring (uncalibrated + calibrated) for ongoing comparison
3. Display the calibrated score in the app when available
4. Disable OpenAI as a summary provider (only Gemini and Claude)

## Design

### Feedback Loading

Before the eval stage, the daily-agent:
1. Scans `feedback/{date}.json` files backwards from today, up to 30 calendar days
2. Collects all feedback entries until it has enough data
3. If fewer than 5 total ratings exist, skip calibration — eval runs with the standard prompt unchanged (uncalibrated only)

**URL format note:** Feedback entries store HTTPS public URLs (e.g., `https://storage.googleapis.com/tsvet01-agent-brain/summaries/gemini/2026-03-14.md`). To download from GCS, strip the `https://storage.googleapis.com/{bucket}/` prefix to get the object path. This matches the existing pattern in the eval stage.

### Few-Shot Context Building

When 5+ ratings are available, the daily-agent builds two types of calibration context:

**Anchor examples:** The 2 most recent "up" and 2 most recent "down" rated summaries. Downloads their content from GCS and includes ~200 word excerpts. Each excerpt is prefixed with the article title for context.

**Polarity requirement:** Calibration requires at least 1 "up" AND 1 "down" rating. If all ratings are the same polarity (e.g., 5 "up" and 0 "down"), skip calibration and run uncalibrated only. One-sided calibration would bias the judge.

**Preference pairs:** Deferred to a future iteration. Matching pairs requires cross-referencing feedback URLs against manifest entries to find summaries of the same underlying article on the same date — more complex than the value justifies with limited data. When implemented later, a preference pair is: two ratings from the same `feedback/{date}.json` file where both summaries share the same `original_url` in the manifest, and the user rated one "up" and the other "down".

### Eval Prompt Injection

The calibration context is prepended to the eval prompt:

```
## User Calibration

The user rated these summaries highly:
[Title: "Article Title 1"]
[Summary 1 excerpt - first ~200 words]

[Title: "Article Title 2"]
[Summary 2 excerpt - first ~200 words]

The user rated these summaries poorly:
[Title: "Article Title 3"]
[Summary 3 excerpt - first ~200 words]

[Title: "Article Title 4"]
[Summary 4 excerpt - first ~200 words]

Use these as reference points when scoring. Align your quality assessment with the user's demonstrated preferences.
```

### Dual Scoring

Each day the eval runs two passes on the same summaries:
1. **Uncalibrated** — standard prompt (current behavior)
2. **Calibrated** — prompt with few-shot feedback injected

Both scores stored. The calibrated score is what appears in the app via `manifest.json`.

**Cost impact:** +1 Claude call per day when calibration is active. Estimated ~$0.01-0.05/day depending on summary count. Negligible relative to existing pipeline cost (~$0.10-0.30/day).

### Storage

The daily-agent writes two separate eval files:
- `eval/{date}.json` — uncalibrated scores (current format, unchanged)
- `eval/{date}-calibrated.json` — calibrated scores (same format)

The daily-agent then merges them in memory before updating `manifest.json`: for each summary, writes `eval_score` from the calibrated result when available, falls back to uncalibrated.

This avoids modifying the existing eval JSON schema and keeps both results independently inspectable.

### Display

No UI changes. The app already shows one eval score — it just becomes the calibrated score when enough feedback exists. Agreement tracking logged by the daily-agent: `"Calibration agreement: 80% (4/5 last ratings)"`.

### Disable OpenAI Provider

Remove OpenAI from the summary generation stage. Only Gemini and Claude produce summaries. Update the provider check error message to reflect the reduced set: `"Set at least one of: GEMINI_API_KEY, ANTHROPIC_API_KEY"`.

## Implementation Scope

**Modified files:**
- `apps/daily-agent/src/main.rs` — feedback loading, URL stripping, calibration prompt building, dual eval, disable OpenAI, update error messages
- `apps/daily-agent/src/prompts.rs` — remove OpenAI provider config if referenced

**No changes to:**
- Cloud Function
- Swift or Flutter apps
- Existing `eval/{date}.json` format (new calibrated file is separate)

## Thresholds and Limits

- Minimum ratings for calibration: 5 total, with at least 1 of each polarity (up and down)
- Lookback window: 30 calendar days (collects 5 most recent ratings regardless of gaps)
- Anchor examples: up to 2 "up" + up to 2 "down" (most recent of each)
- Summary excerpt length: ~200 words, prefixed with article title
- Preference pairs: deferred to future iteration
