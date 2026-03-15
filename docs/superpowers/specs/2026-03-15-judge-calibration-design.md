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

### Few-Shot Context Building

When 5+ ratings are available, the daily-agent builds two types of calibration context:

**Anchor examples:** The 2 most recent "up" and 2 most recent "down" rated summaries. Downloads their content from GCS and includes ~200 word excerpts.

**Preference pairs:** If any date has both an "up" and "down" rating (user preferred one variant over another), includes both with the user's preference noted. Only when available — not required.

### Eval Prompt Injection

The calibration context is prepended to the eval prompt:

```
## User Calibration

The user rated these summaries highly:
[Summary 1 excerpt - first ~200 words]
[Summary 2 excerpt - first ~200 words]

The user rated these summaries poorly:
[Summary 3 excerpt - first ~200 words]
[Summary 4 excerpt - first ~200 words]

Use these as reference points when scoring. Align your quality assessment with the user's demonstrated preferences.

## User Preference Pairs
On {date}, the user preferred:
[Preferred summary excerpt]
Over:
[Rejected summary excerpt]
```

### Dual Scoring

Each day the eval runs two passes on the same summaries:
1. **Uncalibrated** — standard prompt (current behavior)
2. **Calibrated** — prompt with few-shot feedback injected

Both scores stored. The calibrated score is what appears in the app via `manifest.json`.

### Storage

`eval/{date}.json` adds fields per entry:

```json
{
  "summary_id": "v1-gemini",
  "scores": { "clarity": 4, "actionability": 3, "information_density": 4, "structure": 4 },
  "total": 0.75,
  "calibrated_total": 0.85,
  "judge_reasoning": "...",
  "calibrated_reasoning": "..."
}
```

`manifest.json` uses `calibrated_total` for `eval_score` when available, falls back to `total`.

### Display

No UI changes. The app already shows one eval score — it just becomes the calibrated score when enough feedback exists. Agreement tracking logged by the daily-agent: `"Calibration agreement: 80% (4/5 last ratings)"`.

### Disable OpenAI Provider

Remove OpenAI from the summary generation stage. Only Gemini and Claude produce summaries. This simplifies the pipeline and reduces API costs.

## Implementation Scope

**Modified files:**
- `apps/daily-agent/src/main.rs` — feedback loading, calibration prompt building, dual eval, disable OpenAI
- `apps/daily-agent/src/prompts.rs` — remove OpenAI provider config if referenced

**No changes to:**
- Cloud Function
- Swift or Flutter apps
- GCS storage structure (additive fields only)
- Eval output schema (new fields are optional, backwards compatible)

## Thresholds and Limits

- Minimum ratings for calibration: 5
- Lookback window: 30 calendar days (collects 5 most recent ratings regardless of gaps)
- Anchor examples: 2 "up" + 2 "down" (most recent of each)
- Summary excerpt length: ~200 words
- Preference pairs: included when available, not required
