# Personal Daily Brief from a Shared Pool

**Decision:** Anton confirmed on 2026-10-18: one shared daily pool of 5–20 articles across interests; each account receives one of those articles, chosen using interests and feedback.
**Status:** Product direction agreed; implementation and production activation remain pending. Defaults below are implementation recommendations, not additional user decisions.
**Delivery plan:** [Personal daily brief](../plans/2026-10-18-personal-daily-brief.md).
**Parent:** [Hetzner pilot](2026-09-01-multiuser-cohorts-design.md). Existing pilot launch gates remain in force.

## Product outcome

The app continues to offer one daily brief, with a history of that account's previous daily briefs. It does not become a ranked list of 5–20 recommendations. Different users may receive different articles, and many users may receive the same article. The pool size is total across interests, not per user or per cohort.

Separate two questions:

- **Pool quality and coverage:** did we select worthwhile articles covering the interests of our users?
- **Personal match:** did we choose the most useful available article for this account today?

A strong article can be a poor match for one reader. A weak summary does not mean the reader dislikes its subject. Preserve these distinctions in collection, ranking, and reporting.

## Current implementation boundary

The API already scopes +/-1 `selection` and `brief` feedback to its authenticated `user.id`. It stores `(user_id, feed_id, date, aspect)` and offers a PUT, but no personal read or undo endpoint. The Swift pilot hides the legacy feedback widget, and `PilotAPIClient.request` currently accepts only 200/201 success responses, while feedback PUT returns 204.

The daily selector still consumes GCS legacy feedback without individual user identity. It selects a shared engineering article; current briefs are keyed by `(feed_id, date)`. Multiple articles and individual assignments are new work, not capabilities of the existing cohort tables. Account linking remains deferred: do not merge personal histories merely because emails match.

## Shared pool and reusable content

Keep GCP daily/explorer execution, GCS artifacts, legacy engineering publication, and existing recipients running. Add an opt-in pool publication path through CI releases. Hetzner stores application data and serves assignments; Supabase supplies identity.

- Target 5–20 distinct, qualified articles per daily edition. Use an initial configured target of 5 and a hard maximum of 20. These are recommended rollout defaults.
- Fetch shared sources, deduplicate canonical articles, and choose coverage across declared interests before preparing briefs. An article can cover several interests.
- Store topics, per-topic depth, practical/theoretical emphasis, reading time, source, freshness, and selection provenance. Keep article-quality judgement separate from the existing brief evaluation score.
- Reuse a brief only when article content, format, model and prompt version are compatible. Reuse must not silently cross interest-specific generation variants.
- Publish only complete, readable briefs that pass validation. Publish the edition atomically after preparation; a partially built edition must not change a user's recommendation.
- If fewer than five qualified articles are available, record a degraded edition and alert; do not pad with weak articles to satisfy the target. A generation budget is a ceiling, not a requirement to spend.
- Before any billable pool activation, configure numeric source/token/attempt/currency limits from measured usage. Refuse activation without those limits. Count selection, failed attempts, generation, judging, and exploration. No per-user LLM call is required to rank a prepared pool.

## Account preferences and feedback

Start with explicit, editable interests and preferred technical depth. Recommended initial interest catalog: AI/ML, infrastructure and distributed systems, security, mobile, and engineering leadership. Interests overlap; they are not permanent user segments. New users without preferences receive the general engineering default.

The initial feedback connection ships against today's single engineering brief. Add read, change and undo, durable offline submission, account isolation, and server acknowledgement before claiming feedback is saved. Keep legacy Firebase behavior limited to explicit legacy builds.

Later feedback reasons route to different learning targets:

| Input | Primary target |
| --- | --- |
| More like this | This account's article/topic affinity |
| Not relevant to me | This account's relevance profile |
| Too basic / too advanced | This account's depth preference for the article's topics |
| Already knew this | Novelty and repetition for this account |
| Poor article | Shared article/source quality review, with counts and uncertainty |
| Inaccurate or unclear summary | This brief version's quality; do not lower topic affinity |

Reasons are optional. An unqualified negative selection vote cannot be treated as proof of poor global article quality. Undo removes the signal from subsequent profile calculations. Explicit interest changes take precedence over inferred preferences, and users can reset learned preferences without deleting their account.

Store account identity from verified API authentication, never from a client-supplied user ID or email. Users can read/change only their own feedback for content they are entitled to access. Queue entries and cached feedback include the immutable account and content identity. Logout cancels in-flight UI effects and suspends that account's queue; signing in as another account cannot submit it. Returning to the original account can resume its queue after access is rechecked.

Use a revisioned server record, including tombstones for undo. Clients serialize their account's writes and send the last known revision. Conflicts reload server state and require a fresh user action rather than automatically overwriting another device's newer choice. A retry after an uncertain network result first reads the server state and treats an already-matching value as acknowledged.

## One stable assignment each day

Recommended first release keeps the existing 06:00 UTC publication cycle and UTC edition date. Per-user local-midnight delivery is deferred. The app displays the edition date explicitly.

Use an explainable, versioned ranker over the qualified shared pool. For the small pilot, explicit interests and per-topic depth are the primary signals; personal feedback adjusts them gradually. Cohort aggregates are a cautious starting signal, with unique-user counts, and never override a user's explicit preferences. Do not fit collaborative-filtering models from a handful of readers.

Prefer unseen content, avoid near duplicates, and balance relevance with occasional adjacent-topic discovery. Discovery must stay within content-quality and user exclusion constraints. Exact scoring weights and exploration frequency are versioned configuration to calibrate in offline fixtures and shadow mode, not claims agreed with Anton. Freeze a tested baseline before activation; record every assignment's scoring version.

Persist a unique `(user_id, edition_date)` assignment with article ID, exact brief version, edition ID, preference revision, ranker version, selection reason, and fallback/degraded status. All app reads, email and push resolve this same record. Refresh, retries, new pool candidates, or feedback must not silently replace today's assignment. New feedback affects later assignments. A requested same-day replacement is a separate feature and is deferred.

Run assignment creation from scheduled publication and for a newly admitted account on first access. Concurrent requests return the same winning database row. An assignment can exist without the user having seen it; record actual display separately.

On pool/ranker failure, assign the qualified legacy engineering brief through the same stable-ID path and label it as a fallback. Once delivered, keep it stable for the day. If all available content violates hard exclusions or no usable content exists, show explicit unavailability and prior history; do not invent a brief or repeatedly notify. A moderation withdrawal can make an assigned item unavailable, but must not silently substitute another item.

## Additive data and API evolution

Keep existing `(feed, date)` routes and GCS consumers compatible during rollout. Introduce these concepts additively:

- `articles`: stable article identity and canonical source reference; URL normalization must not merge distinct content.
- `article_briefs`: immutable, versioned payloads tied to an article and generation provenance.
- `daily_editions` / `edition_items`: atomic shared pool, edition status, article metadata, and a reference to a complete brief version.
- `user_preferences`: explicit interests, depth and exclusions, learned-signal reset timestamp, revision.
- `daily_assignments`: stable account/day selection and its decision provenance.
- `article_feedback`: account/article aspect, optional reason, revision/tombstone; brief-quality votes also reference the exact brief version.
- `recommendation_events`: minimal idempotent display/read/listen events referencing an assignment, not arbitrary third-party URLs.

Map legacy engineering `(feed, date)` to canonical article/brief IDs before backfilling assignments or feedback. Preserve existing feedback semantics; old `selection` votes carry an unspecified reason. Do not convert pooled legacy anonymous feedback into named account history.

Proposed new interfaces: `GET /v2/me/daily-brief?date=YYYY-MM-DD`, `GET /v2/me/daily-briefs?before=YYYY-MM-DD`, `GET/PUT /v2/me/preferences`, and authenticated feedback keyed by stable article/brief IDs. Details and ownership are fixed in the delivery plan. Personal endpoints and caches must never expose another account's assignment or state.

## Evaluation, delivery, and rollout

Track shared-pool topic coverage, qualified count, generation cost, fallback rate, and quality complaints separately from personal relevance feedback, depth mismatch, usefulness, and repeat avoidance. A missing click is unknown, not a negative vote. Reading/listening is a weaker supporting signal; the objective is useful daily content, not time spent in the app. Avoid inferring preferences from playback failures or autoplay alone.

Record assignment, actual display, feedback and ranker versions so we can compare the personal choice against the general engineering baseline. Start with replay fixtures and shadow assignments; do not alter delivery during shadow mode. Small pilot reports show sample counts and individual improvements, without claims of statistical significance. Recommended event retention: 90 days for raw interaction events, with account deletion support; retain assignments for user history and feedback until undo/account deletion.

Notification idempotency becomes `(assignment_id, channel)` in the personal path. The worker rechecks account access and channel preferences and uses the assignment's exact content. Maintain one sender per recipient/channel. Historical migration and shadow work send no messages. Enabling personal delivery requires the existing durable-outbox and two-account delivery gates; it is not unlocked by ranking tests alone.

Order: connect account feedback -> stable content identity and preferences -> bounded shared pool -> shadow assignments -> personal app/history and delivery -> invite expansion. Disable personal assignment creation to roll back, while retaining existing assignments/history and the working GCP engineering path. Feature flags do not undo migrations or discard user feedback.

## Explicitly deferred

Per-user generated summaries, 5–20 articles per cohort, a recommendation-list home screen, automatic identity linking, same-day replacement, local-midnight schedules, self-service source/feed creation, Android, and GCP shutdown. Existing pilot reliability and distribution work remains necessary.
