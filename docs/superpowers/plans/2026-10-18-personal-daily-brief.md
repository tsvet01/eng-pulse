# Personal Daily Brief Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve each account one stable daily brief chosen using interests and feedback from a shared daily pool of 5–20 articles.

**Architecture:** Retain GCP generation and legacy engineering publication. Add bounded shared-pool preparation and immutable content IDs; Hetzner stores account feedback/preferences and selects one daily assignment. The app and notification worker read the same assignment.

**Tech Stack:** Rust/axum/sqlx/Postgres, existing GCP jobs/GCS, Supabase JWT identity, Swift/SwiftUI/PilotCore, existing GitHub CI.

**Spec:** [Personal daily brief design](../specs/2026-10-18-personal-daily-brief-design.md).

## Global Constraints

- One shared daily pool of 5–20 articles across interests; each account receives one of those articles, chosen using interests and feedback.
- Initial configured target: 5; hard maximum: 20. Degraded editions may contain fewer qualified items and must be reported.
- Keep the existing 06:00 UTC publication cycle and UTC edition date for the first release.
- Preserve GCP daily/explorer execution, legacy engineering payloads/manifest, existing clients and sender routing.
- No client-supplied account identity, cross-account cached state, or cross-account queued writes.
- No LLM calls on app refresh. Pool generation remains disabled until numeric spend/token/source/attempt limits are configured and enforced.
- Preserve current pilot launch gates, CI deployment approvals, and account revocation checks. Documentation approval does not activate generation or delivery.
- New migrations are additive; take the next available number at implementation time. Do not rename deployed migrations.
- Shipping slices are separate small PRs; do not combine this roadmap into one implementation PR.

## Review Focus

- Account A's queued feedback and late responses after switching to B must never affect B — Task 2.
- Undo, stale writes, and uncertain acknowledgements across two devices must not resurrect feedback — Tasks 1–2.
- The same article in multiple interests or regenerated briefs must retain correct article/brief attribution — Task 3.
- Concurrent publication, retry, and first access must create one stable assignment and one logical delivery per channel — Tasks 5–6.
- An incomplete pool, exhausted budget, all-seen candidates, or withdrawn content must leave an honest, readable state — Tasks 4–6.

## File and responsibility map

| Area | Existing entry points | New focused modules |
| --- | --- | --- |
| Account feedback | `apps/pulse-api/src/routes/briefs.rs`, `src/db/feedback.rs`, `tests/briefs.rs` | `tests/feedback.rs`; next migration for revision/tombstone fields |
| Swift feedback | `apps/mobile-swift/EngPulse/Pilot/PilotAPIClient.swift`, `PilotAccountModel.swift`, `Views/DetailView.swift` | `Pilot/PilotFeedback.swift`, `Views/PilotFeedbackView.swift`, `PilotTests/PilotFeedbackTests.swift` |
| Identity / preferences | `libs/pulse-core/src/lib.rs`, API `src/routes/mod.rs`, `src/db/mod.rs`; Swift `Views/SettingsView.swift` | API `src/db/articles.rs`, `src/db/preferences.rs`, `src/routes/preferences.rs`, `tests/personal_content.rs`; Swift `Pilot/PilotPreferences.swift`, `Views/PilotPreferencesView.swift`, `PilotTests/PilotPreferencesTests.swift` |
| Shared pool | `apps/daily-agent/src/main.rs`, `api_client.rs`, `prompts.rs`; API `src/routes/internal.rs` | agent `src/pool.rs`; API `src/db/editions.rs`, `tests/editions.rs` |
| Daily assignment | API `src/lib.rs`, `src/config.rs`, `src/routes/mod.rs` | API `src/personalization.rs`, `src/db/assignments.rs`, `src/routes/daily.rs`, `tests/assignments.rs` |
| Personal reader | Swift `PilotFeedReader.swift`, `PilotAccountModel.swift`, cache/audio mapping | `Pilot/PilotDailyReader.swift`, `PilotTests/PilotDailyReaderTests.swift` |
| Delivery | existing pilot plan's notification/outbox task; API routes/worker wiring | add assignment-based delivery to the notification modules created by that task |

New Swift files must be registered in `apps/mobile-swift/EngPulse.xcodeproj/project.pbxproj` where required. `apps/mobile-swift/Package.swift` already includes the `EngPulse/Pilot` directory; keep new core logic Foundation-only for package tests. Generate contract fixtures through `libs/pulse-core/src/bin/fixtures.rs`, never edit generated JSON manually.

---

### Task 1: Complete account feedback read/change/undo on the current brief

**Files:** API `src/routes/briefs.rs`, `src/db/feedback.rs`, next migration, `tests/feedback.rs`; reuse `tests/common/mod.rs` and existing authentication tests.

**Interfaces:** Keep existing PUT `/v1/briefs/{slug}/{date}/feedback` compatible. Add GET at that path returning only the caller's records, and DELETE `.../feedback/{aspect}` for `selection|brief`. The pilot sends `X-Expected-Revision: N`: 0 means no prior record; server revisions start at 1 and increment atomically. Include each aspect's revision in GET and `X-Feedback-Revision` in successful mutation responses; a mismatch returns 409 with error `feedback_conflict`. A deleted record remains a tombstone with its revision. Legacy PUT without a conditional header retains existing compatibility but increments the revision.

- [ ] Add failing database/HTTP cases: two users rate the same brief independently; GET reveals only self; membership/revocation reject every operation; missing brief rejects writes; invalid aspect/value rejects; change and undo persist; a stale expected revision returns 409 and leaves state unchanged; stale PUT after DELETE cannot resurrect a vote. A compatibility PUT increments the same revision.
- [ ] Run `cargo test -p pulse-api --test feedback` against a disposable Postgres database and confirm failures for missing behavior, not missing infrastructure. Use the harness in `tests/common/mod.rs`.
- [ ] Implement revision-aware feedback records/queries and the routes. A repeated DELETE of an already-deleted current revision is a no-op. Keep the current internal export compatible and exclude tombstones from active signals. Do not connect this data to the shared GCP selector yet.
- [ ] Run `cargo test -p pulse-api --test feedback --test briefs --test auth` against disposable Postgres; expect zero failures. Review query ownership and indexes with two-account fixtures.
- [ ] Commit only API/migration/test changes as `feat(api): complete account feedback lifecycle`.

### Task 2: Wire durable account feedback into the pilot app

**Files:** Swift `PilotAPIClient.swift`, new `PilotFeedback.swift`, `PilotAccountModel.swift`, `Views/DetailView.swift`, new `Views/PilotFeedbackView.swift`, `PilotTests/PilotFeedbackTests.swift`, project registration and focused iOS view tests.

**Interfaces:** Add `PilotFeedbackSnapshot` containing current `selection`/`brief` values and revisions. `PilotFeedbackStore` stores snapshots and pending intents under API user + Supabase identity + feed/date/aspect. `PilotFeedbackClient` exposes `load`, `set(value:expectedRevision:)`, and `clear(expectedRevision:)` using the existing `PilotSession`. Extend authenticated HTTP handling to return status/headers and accept 204 for mutations without making model reads accept empty bodies. Decode `feedback_conflict` separately from the existing 409 account-identity conflict.

- [ ] Add failing tests for GET, 204 PUT/DELETE, token refresh, offline restart, coalesced local changes, A -> logout -> B with queued writes and late responses, returning to A, revoked access, stale-device conflict, and response loss after a successful server write. Assert no mutation is sent using B's session for A's queue.
- [ ] Run `swift test --package-path apps/mobile-swift`; confirm the new cases fail for the intended missing behavior.
- [ ] Implement a serial per-account queue with durable pending state and retry after transient failures. On an uncertain result, reload: matching desired state acknowledges the intent; a different server revision becomes a visible conflict, with no automatic overwrite. Bind completion to the active session generation.
- [ ] Add the pilot widget with “Article relevance” and “Summary quality”, thumbs up/down, undo, and pending/failed state. Read server state on another device; keep the legacy widget behind the legacy build gate. Do not interpret a generic down vote as a global quality failure.
- [ ] Run package tests and relevant iOS tests. Verify two accounts, offline queue/restart, undo, and one real authenticated PUT/GET/DELETE through the normal app path; record build and API revision without credentials. This is the first independently useful release slice.
- [ ] Commit as `feat(ios): sync personal feedback with account isolation`.

### Task 3: Add stable content identities and explicit preferences

**Files:** New API migrations, `src/db/articles.rs`, `src/db/preferences.rs`, `src/routes/preferences.rs`, module wiring, `tests/personal_content.rs`; `libs/pulse-core/src/lib.rs` and fixture generator. Later stable-feedback routes live in `src/routes/article_feedback.rs` with tests in `tests/feedback.rs`. Swift preferences use the new files in the responsibility map and `Views/SettingsView.swift`.

**Interfaces:** Define shared `ArticleId`, `BriefId`, `EditionId`, `AssignmentId` UUID-backed types and `ArticleFeatures` (topic list, per-topic depth, emphasis, reading minutes). Add immutable `article_briefs`; keep the legacy briefs table/routes. `GET/PUT /v2/me/preferences` returns/updates explicit interests, per-topic depth, exclusions, reset timestamp and revision. Stable feedback endpoints are `GET/PUT/DELETE /v2/articles/{article_id}/feedback/{aspect}` for `relevance|depth|novelty|article_quality|brief_quality`; `brief_quality` requires an entitled `brief_id` query parameter for all three methods and has independent state per brief version. Other aspects refer to the article. Preferences use the same conditional revision pattern with `preference_conflict` on mismatch.

- [ ] Add failing tests for canonical deduplication without conflating different content; one article in two interests; two brief revisions; exact payload preservation; replay-safe legacy mapping/backfill; independent user preferences; entitlement checks; feedback undo and learned-preference reset. Generic historic `selection` maps to relevance with unspecified reason; `brief` maps to the original brief version.
- [ ] Run the new API tests and confirm the expected failures.
- [ ] Implement additive tables, legacy mapping, preference API and stable feedback using Task 1's concurrency rules. Persist optional reason enums from the spec; reject incompatible aspect/reason pairs. Preserve original rows and legacy endpoints; map later v1 writes through the same canonical record so the two routes cannot diverge. API derives account identity from JWTs.
- [ ] Extend the Swift feedback adapter and queue migration to stable IDs. Resolve old pending entries through the server's legacy mapping; missing mappings remain pending with an error rather than being submitted against a guessed article. Add editable preferences and a reset action; resetting learned preferences leaves explicit interests intact.
- [ ] Run API and Swift tests, regenerate contract fixtures, and run `scripts/check-brief-contracts.swift` through its existing CI invocation. Verify backfill/replay makes no model calls and sends no notifications.
- [ ] Commit API/contracts and Swift adaptation as separately reviewable PRs under this task's shared contract.

### Task 4: Prepare and publish the bounded shared daily pool

**Files:** agent `src/pool.rs`, `main.rs`, `api_client.rs`, `prompts.rs`; API `src/db/editions.rs`, `src/routes/internal.rs`, `tests/editions.rs`; configuration and CI deployment validation. Consult the current release scripts before adding flags.

**Interfaces:** `PoolConfig` has enabled, target_items=5, max_items=20, source/token/attempt limits and daily currency budget. `PreparedEdition` has UTC date, complete item references, features/provenance and normal/degraded status. Add idempotent `POST /internal/editions` that validates and atomically publishes a complete edition; unpublished drafts are never assignment candidates.

- [ ] Add failing unit/integration cases for overlap between interests, 20-item cap, underfilled qualified pool, partial generation failure, missing numeric budget configuration, retry after a billable failure, compatible artifact reuse, changed prompt/content invalidating reuse, and identical publication replay. Verify legacy engineering artifacts remain unchanged with pool mode off.
- [ ] Run `cargo test -p daily-agent` and `cargo test -p pulse-api --test editions`; confirm the new cases fail for the intended behavior.
- [ ] Implement pool preparation behind a default-off flag. Select diverse candidates before generation, persist every billable attempt/reservation durably across process restarts, and enforce budgets before calls. Publish only validated completed content; retain the independent engineering fallback and existing manifest contract.
- [ ] Run fixtures and a dry run with recorded candidates and stubbed providers. Then run a bounded billed sample only after configured limits and existing production approvals are satisfied; record actual spend and article counts. Do not promise that shared reuse removes per-article generation/judging cost.
- [ ] Commit the API publication contract first, then agent support. Release API readiness before enabling the agent integration through CI.

### Task 5: Choose and persist one daily assignment in shadow mode

**Files:** API `src/personalization.rs`, `src/db/assignments.rs`, `src/routes/daily.rs`, migrations, `src/lib.rs`, `src/config.rs`, `tests/assignments.rs`.

**Interfaces:** `rank_candidates(profile, candidates, history, policy) -> Vec<RankedCandidate>` is pure and returns reasons/component scores. `assign_daily(pool, user_id, edition_date, mode) -> AssignmentOutcome` persists at most one account/date assignment; mode is shadow or live in separate namespaces. Outcomes are assigned (normal/fallback) or unavailable with a reason. `GET /v2/me/daily-brief?date=` returns a persisted assignment and exact immutable brief. `GET /v2/me/daily-briefs?before=` paginates that account's assignment history.

- [ ] Add failing tests for two profiles selecting different articles; many users sharing one; explicit preferences overriding inferred/cohort signals; generic dislike versus poor quality; depth reasons scoped to topic; undo/reset removing learned influence; empty/new profiles; absent interactions not counting as dislikes; no cross-account reads.
- [ ] Add failure/concurrency tests: simultaneous scheduler and GET; retry after transaction success; feedback/pool updates after assignment; revoked user; incomplete edition; hard exclusions; all-seen pool; legacy fallback; missing/withdrawn content; shadow mode producing no live assignments or messages. Assert one stable row per account/date and stored decision provenance.
- [ ] Run `cargo test -p pulse-api --test assignments` and confirm expected failures.
- [ ] Implement versioned explainable scoring and database conflict handling. Freeze a baseline policy with explicit numeric weights after replay comparison; keep the policy in versioned configuration. Prefer unseen content, permit labelled repeats only when eligible unseen content is exhausted, and apply hard exclusions before any fallback. History reads never create backdated assignments. Current-day GET may create an assignment for a newly admitted account.
- [ ] Run replay fixtures and shadow comparisons against the general engineering choice. Report pool coverage, fallback/repeat rates, explicit relevance and depth signals with unique-user/sample counts. Document policy version and acceptance examples before live selection; avoid significance claims from the five-user pilot.
- [ ] Commit as `feat(api): persist personal daily assignments behind rollout flags`.

### Task 6: Connect personal history and assignment-based delivery

**Files:** Swift `PilotDailyReader.swift`, `PilotFeedReader.swift`, `PilotAccountModel.swift`, `PilotDailyReaderTests.swift`, existing summary/cache/TTS mapping; API notification modules from the parent pilot's durable-outbox task, event routes/tests, operating runbook.

**Interfaces:** Personal list entries reference assignment/article/brief IDs; cache keys include account and immutable brief ID. The notification outbox references `(assignment_id, channel)`. Add `POST /v2/me/recommendation-events` for idempotent assignment-scoped displayed/read/listen milestones, with server-validated ownership and minimal fields. A display event is distinct from assignment creation or push-provider acceptance.

- [ ] Add failing reader tests for one daily item plus personal history, stable refresh, date rollover, offline startup, account switching, unchanged content/audio identity, labelled fallback/repeat, unavailable/withdrawn content, and pagination. Ensure a background playback interruption does not generate negative feedback.
- [ ] Add notification/event tests for app/email/push content agreement, concurrent workers, duplicate retries, preference/revocation changes, silent backfill/shadow, idempotent events, 90-day raw-event expiry, account deletion, and sender rollback. Retain the documented at-least-once provider boundary; no exactly-once claim.
- [ ] Implement the personal reader behind a per-account rollout flag and preserve the legacy engineering reader. Add lightweight optional feedback reasons and preference controls. Keep the daily home focused on one assigned item; do not add a ranked pool browsing screen.
- [ ] Integrate assignments with the parent plan's durable outbox only after its retry/ownership/sender gates pass. Record actual display separately from server delivery. Add pool/assignment/budget/fallback alerts and an operator view that separates shared quality from personal fit.
- [ ] Run package/iOS/API checks, then verify two real accounts get one appropriate stable brief across app/email/push, with feedback affecting a later assignment and offline/account isolation intact. Confirm a legacy recipient still works and rehearse disabling new assignments without losing existing history.
- [ ] Commit small reader/delivery/observability PRs; record real release evidence in the parent pilot checklist before expanding invitations.

## Verification and handoff

All implementation checkboxes are intentionally open. These documents do not claim account feedback, multi-article generation or personal delivery is live. Keep API/agent/iOS revisions and real checks with each release slice. Start implementation with Tasks 1–2; Tasks 3–6 are subsequent separately reviewed slices and must preserve their explicit interfaces and launch gates.

For database tests, use the disposable Postgres harness in `apps/pulse-api/tests/common/mod.rs` and the setup used by `.github/workflows/ci.yml`; never point test resets at production. Use the repository's current iOS test destination rather than hard-coding a physical device ID. No new infrastructure or production changes belong to this documentation update.
