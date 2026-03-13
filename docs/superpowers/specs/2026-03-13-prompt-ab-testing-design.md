# Prompt A/B Testing with Eval System

## Problem

The daily-agent uses generic, unstructured prompts for article selection and summarization. The selection prompt doesn't reflect the reader's actual interests, and the summary prompt produces inconsistent, unstructured output that varies wildly between models. There's no mechanism to measure summary quality or iterate on prompts without blind deploys.

## Solution

Add a parallel beta pipeline that runs persona-driven, structured prompts alongside the existing production prompts. Include an automated LLM judge and user feedback mechanism to compare quality. Mobile apps can toggle between production and beta views.

## Reader Persona

> Engineering leader and systems programmer (C++/Rust/Python/Go) in quantitative finance, building developer platforms at a hedge fund in London. 20 years across storage systems, derivatives risk, and WhatsApp commerce. Obsessed with low-level performance, AI-assisted development, and the builder-vs-manager tension. Side interests: arthouse cinema, opera, qigong, skiing, psychology of adult development.

### Interest Areas (for article selection)

**Core technical:** C++ (modern standards, performance, SIMD/vectorization, memory models), Rust (systems programming, async, ecosystem evolution), Python (language future, typing, performance, packaging), low-latency/high-performance computing, vector search/similarity search/embedding infrastructure, distributed systems architecture.

**Platform & developer experience:** CI/CD, build systems, release engineering, internal developer portals/developer productivity, microservices observability, reliability, platform engineering, DevOps/GitOps practices at scale.

**AI & LLM tooling:** LLM-assisted coding (agentic workflows, code generation, multi-agent systems), AI engineering (RAG, tool use, prompt engineering, MCP), local/open-source LLMs, inference optimization.

**Quantitative finance & trading technology:** Trading systems architecture, real-time pricing/risk/P&L systems, hedge fund technology strategy, market microstructure.

**Engineering leadership:** Staff/Principal engineer career paths, technical strategy and decision-making, engineering management vs IC tradeoffs, scaling engineering organizations.

**Vim/Neovim/terminal tooling:** Neovim plugins, LazyVim configuration, terminal workflows (tmux, CLI tools, dotfiles).

**Personal development & psychology:** Adult developmental psychology (Kegan, vertical development), Schema Therapy, AEDP, internal family systems, coaching methodology, Process Communication Model.

**Culture (lower priority):** Arthouse/international cinema, opera, qigong/tai chi/internal martial arts, skiing.

## Architecture

### Prompt Configuration Module

New file: `apps/daily-agent/src/prompts.rs`

Prompts are defined as associated functions on a `PromptConfig` struct with `&'static str` version identifiers. Each version is a `const` instance:

```rust
pub struct PromptConfig {
    pub version: &'static str,
}

impl PromptConfig {
    pub const V1: Self = Self { version: "v1" };
    pub const V2: Self = Self { version: "v2" };
}
```

Each version provides `selection_prompt(&self, articles_text: &str) -> String` and `summary_prompt(&self, source: &str, title: &str, content: &str) -> String` methods via a `match self.version` dispatch. This avoids bare function pointers and keeps prompt text as plain string formatting.

**Important:** The V1 prompts MUST be copied verbatim from the live `main.rs` (lines 155-158, 203-206), not from the transcriptions below which may have minor whitespace differences.

#### V1 Selection Prompt (prod, unchanged)

```
You are an expert Software Engineering Editor. Review the following list of article
headlines collected today. Select the SINGLE most valuable, educational, and impactful
article for a senior software engineer to read. Consider technical depth, novelty,
and broad relevance.

{articles_text}

Reply ONLY with the integer index number of the chosen article (e.g., '3').
Do not add any explanation.
```

#### V2 Selection Prompt (beta)

```
You are curating a daily technical digest for this reader:

{persona — full text from Reader Persona section above}

Their interest areas: {interest areas — abbreviated list}

From today's articles, select the SINGLE most valuable one. Prioritize:
1. Actionable insight they can apply this week
2. Technical depth — not surface-level news or beginner content
3. Novelty — fresh perspective, not common knowledge
4. Relevance to their specific role and interests

Avoid: product announcements, vendor marketing, beginner tutorials, pure news without insight.

{articles_text}

Reply ONLY with the integer index number (e.g., '3'). No explanation.
```

#### V1 Summary Prompt (prod, unchanged)

```
Please summarize the following software engineering article in a compact and
educational format. Focus on key takeaways, core concepts, and why it matters
to a software engineer. Ignore any promotional or fluff content.

Article Source: {source}
Title: {title}
Content: {content}
```

#### V2 Summary Prompt (beta)

```
Summarize this article in exactly this structure (400-500 words total):

## {concise title, 8-12 words}

**{one-line hook: why this matters to an engineering leader}**

### Key Points
- **{bold lead phrase}**: {explanation}
(3-5 bullets, each self-contained)

### Why It Matters
{2-3 sentences connecting to real engineering work — architecture decisions,
team impact, or industry shift}

### Action Items
- {1-2 specific, concrete things to evaluate or do this week}

Rules:
- Reader is a senior engineering leader who builds developer platforms at a hedge fund
- No fluff, no filler, no "in conclusion", no "in summary"
- Bold the lead phrase of each bullet for scannability
- Each paragraph max 50 words (mobile readability)
- Be specific and opinionated, not hedging
- Ignore promotional content

Article Source: {source}
Title: {title}
Content: {content}
```

### Pipeline Stages

```
main()
  ├── Stage 1: Fetch
  │     Collect articles from all sources (shared, unchanged)
  │     Result: Vec<Article>
  │
  ├── Stage 2: Prod (v1)
  │     v1 selector picks article A
  │     Fetch article A content (once, stored in variable for reuse)
  │     Generate 3 summaries (Gemini, OpenAI, Claude) with v1 prompt
  │     Upload to summaries/{provider}/{date}.md
  │     Append to in-memory manifest entries (prompt_version: null)
  │
  ├── Stage 3: Beta (v2) — failure is non-fatal, requires ANTHROPIC_API_KEY
  │     v2 selector picks article B
  │     v2 summarizer runs on article A (reuses fetched content) → summaries/beta/claude/{date}.md
  │     If B ≠ A: fetch article B, v2 summarizer → summaries/beta/claude/{date}-selection.md
  │     Append to in-memory manifest entries (prompt_version: "v2")
  │     Beta article B entry gets original_url: article B's URL (not article A's)
  │
  └── Stage 4: Eval — failure is non-fatal, requires ANTHROPIC_API_KEY
        LLM judge (Claude) scores all summaries from today
        Upload eval/{date}.json
        Update in-memory manifest entries with eval_score
        ↓
        Single manifest.json upload (download once at start, all stages append in-memory, one final upload)
```

**Manifest update invariant:** The manifest is downloaded from GCS **once** at the start of `main()`. All stages append to the same in-memory `Vec<ManifestEntry>`. A **single upload** happens at the end, after all stages complete (or fail gracefully). This preserves the current atomic-write behavior and prevents partial manifest states from stage crashes.

**Key behaviors:**
- Stage 2 completes fully before Stage 3 starts. Prod is never blocked by beta.
- **Stage 3 is skipped entirely if `ANTHROPIC_API_KEY` is not set.** Logged as info, not error.
- **Stage 4 is skipped entirely if `ANTHROPIC_API_KEY` is not set.** Logged as info, not error.
- Stage 3 failure (with key present) is logged as warning. Prod summaries already uploaded.
- Stage 4 failure (with key present) is logged as warning. Summaries still available without scores.
- Article A content is fetched once and reused across stages 2 and 3.
- Beta uses Claude as the single provider to keep costs down.
- The beta path `beta/claude/` uses a slash in the GCS object name — this is valid in GCS (slashes are logical separators, not real directories). The path builder must construct this as a single string: `format!("summaries/beta/claude/{}.md", today)`.

### Manifest Schema Changes

```rust
#[derive(Serialize, Deserialize, Debug, Clone)]
struct ManifestEntry {
    date: String,
    url: String,
    title: String,
    summary_snippet: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    original_url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    selected_by: Option<String>,
    // NEW
    #[serde(skip_serializing_if = "Option::is_none")]
    prompt_version: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    eval_score: Option<f64>,
}
```

Backwards compatible: existing entries have `prompt_version: null` and `eval_score: null`. Mobile apps that don't know about these fields ignore them via `skip_serializing_if`.

### GCS Storage Layout

```
summaries/
  gemini/2026-03-13.md              # prod v1
  openai/2026-03-13.md              # prod v1
  claude/2026-03-13.md              # prod v1
  beta/claude/2026-03-13.md         # v2 summary of prod article A
  beta/claude/2026-03-13-selection.md  # v2 summary of beta article B
eval/
  2026-03-13.json                   # eval scores for all summaries
```

### Eval System

#### Tier 1: LLM Judge (automatic, in daily-agent Stage 4)

After all summaries are generated, Claude scores each on 4 criteria (1-5 scale):

```rust
#[derive(Serialize, Deserialize, Debug, Clone)]
struct EvalReport {
    date: String,
    scores: Vec<EvalEntry>,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct EvalEntry {
    /// Composite key: "{prompt_version}-{model}", e.g. "v1-gemini", "v2-claude"
    summary_id: String,
    prompt_version: String,
    model: String,
    title: String,
    scores: EvalCriteria,
    total: f64,              // normalized 0.0-1.0 (sum of 4 scores / 20)
    judge_reasoning: String, // one-line explanation
}

#[derive(Serialize, Deserialize, Debug, Clone)]
struct EvalCriteria {
    clarity: u8,             // how easy to scan and understand (1-5)
    actionability: u8,       // concrete takeaways vs vague advice (1-5)
    information_density: u8, // signal-to-noise ratio (1-5)
    structure: u8,           // formatting, sections, mobile readability (1-5)
}
```

**Summary ID convention:** Each summary is identified by `"{prompt_version}-{provider}"`, e.g., `"v1-gemini"`, `"v1-openai"`, `"v1-claude"`, `"v2-claude"`, `"v2-claude-selection"`. The pipeline constructs these IDs when building the eval prompt, and parses them from the judge's JSON response to map scores back to manifest entries. The mapping logic: split on first `-` to get `prompt_version`, remainder is `model` (with optional `-selection` suffix for beta's own pick).

Eval prompt:

```
You are evaluating article summaries for quality. Score each summary on these criteria (1-5):

1. Clarity: How easy is it to scan and understand on a mobile phone?
2. Actionability: Does it provide concrete takeaways the reader can act on this week?
3. Information density: What is the signal-to-noise ratio? Is every sentence valuable?
4. Structure: Is it well-formatted with clear sections, bold key phrases, scannable bullets?

The reader is a senior engineering leader. They have 2-3 minutes on their phone.

For each summary below, return ONLY a JSON object (no markdown fences):
{
  "scores": [
    {
      "summary_id": "v1-gemini",
      "clarity": 4,
      "actionability": 3,
      "information_density": 4,
      "structure": 2,
      "reasoning": "Clear content but wall-of-text format hurts mobile readability"
    }
  ]
}

--- Summary: v1-gemini ---
{summary text}

--- Summary: v1-openai ---
{summary text}

...
```

#### Tier 2: User Feedback (mobile, stored locally)

Thumbs up/down buttons in the detail view toolbar. Stored locally, instant response. See platform-specific implementation details below.

#### Tier 3: Feedback Tally (mobile settings)

Simple counts displayed in SettingsView:

```
v1  ▲12  ▼3   |   v2  ▲18  ▼1
```

See platform-specific implementation details below.

### Mobile UI Changes (Swift)

All changes are minimal additions to existing views. No new screens, no new navigation.

#### Summary Model — New Fields

```swift
struct Summary {
    // ... existing fields ...
    let promptVersion: String?   // "v1", "v2", or nil (nil = v1)
    let evalScore: Double?       // 0.0-1.0, nil = not scored
}
```

**Important:** New optional properties must have `= nil` default values in the struct definition to avoid breaking the synthesized memberwise initializer. All existing call sites (including `Summary.preview` and `Summary.previewList`) will continue to compile without changes.

#### SettingsView — Prompt Version Filter

Add a `Picker` in the existing settings list:

```swift
@AppStorage("promptVersionFilter") private var promptVersionFilter: String = "production"

Picker("Summary Format", selection: $promptVersionFilter) {
    Text("Production").tag("production")
    Text("Beta").tag("beta")
    Text("Both").tag("both")
}
```

#### SettingsView — Feedback Tally

The tally counts are computed by iterating `UserDefaults.standard.dictionaryRepresentation()` and filtering keys with the `"feedback_"` prefix. This is a lightweight operation (small number of entries) done on-demand when Settings is opened:

```swift
var feedbackTally: (v1Up: Int, v1Down: Int, v2Up: Int, v2Down: Int) {
    let allDefaults = UserDefaults.standard.dictionaryRepresentation()
    var tally = (v1Up: 0, v1Down: 0, v2Up: 0, v2Down: 0)
    for (key, value) in allDefaults {
        guard key.hasPrefix("feedback_"), let rating = value as? String else { continue }
        // Determine version by checking if the URL contains "/beta/"
        let isBeta = key.contains("/beta/")
        switch (isBeta, rating) {
        case (false, "up"):  tally.v1Up += 1
        case (false, "down"): tally.v1Down += 1
        case (true, "up"):   tally.v2Up += 1
        case (true, "down"): tally.v2Down += 1
        default: break
        }
    }
    return tally
}
```

#### HomeView — Filter by prompt_version

Extend `filteredSummaries` computed property (same pattern as existing `ModelFilter`):

```swift
@AppStorage("promptVersionFilter") private var promptVersionFilter: String = "production"

// After existing model filter
if promptVersionFilter == "production" {
    result = result.filter { $0.promptVersion == nil }
} else if promptVersionFilter == "beta" {
    result = result.filter { $0.promptVersion == "v2" }
}
// "both" shows all — add a small version badge on each card
```

**Filter composition with ModelFilter:** When `promptVersionFilter == "beta"`, all beta entries use Claude as the model. The existing `ModelFilter` dropdown should be hidden when viewing beta-only (since there's only one model). When viewing "both", the model filter applies across both versions. Implementation: conditionally show the model filter menu only when `promptVersionFilter != "beta"`.

#### DetailView Info Sheet — Eval Score

Add one conditional row in the existing info sheet, caption font, secondary color:

```swift
if let score = summary.evalScore {
    // Score is 0.0-1.0, display as 1.0-5.0 scale (min is 4/20=0.2 → 1.0)
    let displayScore = max(score * 5, 1.0)
    Label(
        String(format: "%.1f/5", displayScore),
        systemImage: "star.fill"
    )
    .font(.caption)
    .foregroundColor(.secondary)
}
```

#### DetailView Toolbar — Feedback Buttons

Two small SF Symbol buttons in the existing toolbar. Note: `@AppStorage` with dynamic keys requires a computed wrapper since `@AppStorage` key must be a string literal or stored property:

```swift
// Use a FeedbackManager helper that wraps UserDefaults directly
private var currentFeedback: String {
    get { UserDefaults.standard.string(forKey: "feedback_\(summary.url)") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "feedback_\(summary.url)") }
}

Button { currentFeedback = currentFeedback == "up" ? "" : "up" } label: {
    Image(systemName: currentFeedback == "up" ? "hand.thumbsup.fill" : "hand.thumbsup")
        .font(.caption2)
}
.tint(currentFeedback == "up" ? .green : .secondary)

Button { currentFeedback = currentFeedback == "down" ? "" : "down" } label: {
    Image(systemName: currentFeedback == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
        .font(.caption2)
}
.tint(currentFeedback == "down" ? .red : .secondary)
```

Compact, no labels, inline with existing toolbar items. Tapping the same button again clears the feedback (toggle behavior).

### Mobile UI Changes (Flutter)

**Note:** Flutter already has a feedback widget (`FeedbackWidget` in `lib/widgets/feedback_widget.dart`) rendered in `DetailScreen` using `UserService.setFeedback()` with Hive storage. The existing feedback UI should be reused — do NOT add duplicate feedback buttons.

Changes needed:

- `summary.dart`: Add `promptVersion` and `evalScore` fields to `Summary.fromJson()`
- `cached_summary.dart`: Add `@HiveField(9) String? promptVersion` and `@HiveField(10) double? evalScore`. **Then run `dart run build_runner build --delete-conflicting-outputs` to regenerate `cached_summary.g.dart`.** Existing Hive boxes handle new nullable fields gracefully (they deserialize as `null`).
- `settings_screen.dart`: Add prompt version dropdown (same 3 options as Swift)
- `home_screen.dart`: Filter by prompt version (same logic as Swift, hide model selector when viewing beta-only)
- `detail_screen.dart`: Show eval score badge in the info section. Reuse existing `FeedbackWidget` — no new feedback UI needed.

### Files to Modify/Create

| File | Action | Purpose |
|------|--------|---------|
| `apps/daily-agent/src/prompts.rs` | CREATE | Prompt configs v1/v2 with version dispatch |
| `apps/daily-agent/src/main.rs` | MODIFY | 4-stage pipeline, manifest download-once/upload-once |
| `apps/mobile-swift/EngPulse/Models/Summary.swift` | MODIFY | Add promptVersion, evalScore (with `= nil` defaults) |
| `apps/mobile-swift/EngPulse/Views/SettingsView.swift` | MODIFY | Prompt version picker, feedback tally |
| `apps/mobile-swift/EngPulse/Views/HomeView.swift` | MODIFY | Filter by prompt version, conditional model filter |
| `apps/mobile-swift/EngPulse/Views/DetailView.swift` | MODIFY | Eval badge, feedback buttons |
| `apps/mobile/lib/models/summary.dart` | MODIFY | Add promptVersion, evalScore to Summary |
| `apps/mobile/lib/models/cached_summary.dart` | MODIFY | Add @HiveField(9), @HiveField(10), then run build_runner |
| `apps/mobile/lib/screens/settings_screen.dart` | MODIFY | Prompt version dropdown |
| `apps/mobile/lib/screens/home_screen.dart` | MODIFY | Filter by prompt version, conditional model selector |
| `apps/mobile/lib/screens/detail_screen.dart` | MODIFY | Eval score badge |

### Cost Impact

Current daily run: ~4 LLM calls (1 selection + 3 summaries).

New daily run: ~8 LLM calls
- 1 v1 selection (Claude)
- 3 v1 summaries (Gemini, OpenAI, Claude)
- 1 v2 selection (Claude)
- 1 v2 summary of article A (Claude)
- 1 v2 summary of article B (Claude) — only if B ≠ A
- 1 eval call (Claude)

Approximate additional cost: ~$0.10-0.30/day depending on article length. Negligible.

### Future: Closed-Loop Feedback Calibration (Roadmap Item 3)

After A/B testing validates v2 prompts, build a feedback loop:

1. Device periodically uploads ratings to GCS: `feedback/{date}.json`
2. Before eval judge scores new summaries, it loads recent feedback
3. Top-rated and bottom-rated summary examples are injected as few-shot context

```
"Here are summaries the reader rated highly:
 [3 top-rated examples with their text]

 Here are summaries the reader rated poorly:
 [2 low-rated examples with their text]

 Score the following new summary on the same criteria.
 Calibrate your scoring to match this reader's preferences."
```

Few-shot examples from real ratings are more powerful than written criteria. The judge infers taste implicitly — preferences the reader might not even articulate (e.g., preferring concrete code examples over abstract advice, or brevity over completeness).

### Success Criteria

1. Daily agent generates both v1 and v2 summaries without v1 regression
2. Stage 3/4 failures never block prod summaries or manifest upload
3. Mobile app shows correct summaries per filter setting
4. Eval scores appear on detail view info sheet
5. Feedback buttons work (Swift) / existing feedback widget works (Flutter)
6. Feedback tallies display correctly in settings
7. Model filter hides when viewing beta-only (single model)

### Open Questions

None — all questions resolved during design discussion.
