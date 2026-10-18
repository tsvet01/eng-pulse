# Pilot Personal State Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with failing tests before implementation and one fresh whole-branch review at the end.

**Goal:** Let an admitted reader rate an article/brief, safely retry offline ratings, and read/save their engineering email/push preferences.
**Architecture:** Extend the existing authenticated API with current-user feedback reads/deletion and membership-only preference reads/updates. Bind a Swift observable personal-state model and durable local rating queue to each reader context. Keep preference saves online and show that pilot notification delivery is not yet available.
**Tech Stack:** Rust/axum/sqlx/Postgres; Swift/Foundation/Combine/SwiftUI; existing test harnesses.
**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md`, sections 4, 6 and 7; P2 of `2026-10-13-hetzner-multiuser-pilot.md`.

## Global Constraints

- Keep GCP jobs, schedules, generation, legacy feedback and notification recipients unchanged. No direct cloud operations.
- Only active engineering members can read/write their own personal state. Updating preferences must not recreate a removed membership.
- Offline edits retain their identity/user/feed namespace, never the next account's credentials. Logout invalidates active work; pending edits may resume only for the same account after a new admission.
- Store pending writes outside the disposable article cache. Persist before showing a queued rating; clear an edit only after server acknowledgement.
- This first P2 slice does not register APNs devices, enable a sender, invite users, or claim actual email/push delivery. Those are separate slices.
- Existing migration/schema supports these operations; no schema changes or new dependencies.

## Review Focus

- A late network result must not revive state after logout/revocation or overwrite a newer rating.
- Clearing article cache must not delete unsent ratings; another identity cannot see or send them.
- An offline preference change must visibly fail rather than falsely promise opt-out was saved.
- Reads/deletes must enforce membership/account ownership as strictly as feedback writes, including disabled accounts and inactive feeds.
- Notification settings must not imply that delivery works before the outbox, device registration and sender cutover exist.

### Task 1: Current-user API contracts

**Files:** `apps/pulse-api/src/{db/feedback,db/feeds,routes/briefs,routes/feeds}.rs`; `apps/pulse-api/tests/personal_state.rs`.
**Interfaces:** GET `/v1/briefs/{slug}/{date}/feedback` returns `{selection: -1|1|null, brief: -1|1|null}`; existing PUT accepts one aspect/value and returns 204; DELETE takes `{aspect: "selection"|"brief"}` and returns 204 idempotently. GET/PUT `/v1/feeds/{id}/preferences` return `{notify_email: bool, notify_push: bool}`; PUT requires both booleans and updates only an existing membership.

- [ ] Add HTTP/DB tests: two users' ratings remain isolated; deleting one aspect preserves the other and the other user; invalid aspect/value/date/brief denied; preference reads/updates preserve role and do not re-enroll a removed member; unauthorized/disabled/inactive-feed requests rejected.
- [ ] Run `DATABASE_URL=postgres://pulse:pulse@127.0.0.1:55438/pulse cargo test -p pulse-api --test personal_state`; expect missing-route 405/404 failures.
- [ ] Implement the routes and scoped queries without widening existing permissions.
- [ ] Run the focused suite, then the full API suite and Clippy; expect all pass. Commit API/tests.

### Task 2: Account-bound Swift personal state

**Files:** new `EngPulse/Pilot/PilotPersonalState.swift`, `PilotTests/PilotPersonalStateTests.swift`; existing `PilotAPIClient.swift`.
**Interfaces:** `PilotFeedbackAspect`, `PilotFeedback`, `PilotNotificationPreferences`; API methods `feedback`, `setFeedback`, `notificationPreferences`, `setNotificationPreferences`. `@MainActor PilotPersonalState` exposes ratings, pending state, preferences, errors, `refreshFeedback(date:)`, `rate(date:aspect:value:)`, `flush()`, `loadPreferences()`, `savePreferences(_:)`, `invalidate()` and access-failure callback. It accepts API/session/identity-scoped storage URL.

- [ ] Write tests for exact request shapes/204, invalid values, offline durable retry and restart, account separation, in-flight edit supersession, logout during response, server-read racing a local edit, persistence failure, and failed preference saves preserving acknowledged values.
- [ ] Run `swift test --package-path apps/mobile-swift`; expect missing personal-state symbols, then behavioral failures before fixes.
- [ ] Implement the smallest model. Serialize queue draining; compare edit IDs before clearing acknowledged work. Guard every asynchronous boundary with current-session checks. Require valid engineering membership for preferences.
- [ ] Run the complete core suite; expect all pass. Commit model/tests.

### Task 3: Reader and Settings integration

**Files:** `EngPulse/AppServices.swift`, `Views/{PilotSignInView,DetailView,SettingsView}.swift`, new `Views/PilotPersonalViews.swift`, Xcode project; focused `EngPulseTests`; pilot delivery plan.
**Interfaces:** Each `PilotReaderContext` owns one `PilotPersonalState`, invalidates it with the reader and passes it via SwiftUI environment. Feedback appears only in the admitted pilot reader. Settings reads preferences on entry, disables concurrent saves, and explicitly labels notification delivery as not yet available. Foregrounding retries the current account's queue.

- [ ] Add regression tests for context invalidation/namespace separation and pending feedback surviving article-cache clearing; run focused iOS tests, expect failure before wiring.
- [ ] Wire rating controls, pending/error/retry status and preference controls. Keep legacy widgets/services under their existing gate.
- [ ] Run Swift core tests, iOS simulator suite, signed-device build and relevant API checks; expect pass. Update pilot evidence with implemented versus unverified delivery/device gates. Commit.
- [ ] Request one fresh whole-branch review, fix important findings with regression tests, publish a PR and inspect CI. Do not merge this new slice under the separate authorization to merge #202.
