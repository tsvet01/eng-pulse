# iOS Pilot Reader Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline, with tests before code and one fresh whole-branch review at the end.

**Goal:** Let an admitted pilot account read and listen to the engineering feed from the deployed Hetzner API, including previously saved content offline, without exposing another account's state.
**Architecture:** Extend the existing Supabase/API client and admission model in PR #190. Give each admitted session its own reader, disk namespace, AppState and TTS instance; replace the phone/CarPlay context on account changes. Reuse the existing detail renderer and audio pipeline through an injected content loader. Preserve the legacy build's GCS path.
**Tech Stack:** Swift/SwiftUI, Foundation/Combine, existing URLSession and Keychain wrappers, Swift Package tests plus Xcode simulator tests.
**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md`, P2 reader slice of `2026-10-13-hetzner-multiuser-pilot.md`.

## Global Constraints

- Keep GCP daily/explorer jobs, schedules, models, public artifacts and legacy recipients running unchanged. Deploy API only through CI.
- No secrets or device identifiers in git/logs. Use the existing ignored local configuration for signed builds.
- Only active engineering membership permits online reads. Never fall back to public GCS from a pilot reader or send its credentials to artifact URLs.
- Preserve the existing V3 renderer, offline reading, TTS and CarPlay. Account changes invalidate old work and stop playback.
- This slice does not enable feedback/device registration/notification delivery. Hide the legacy feedback controls in pilot reading; complete the API feedback/outbox/sender and real two-account delivery gates before invitations.

## Builder decisions

Fetch the latest 100 API brief summaries (the API's bounded maximum; the initial mirror has 29). Persist that list and downloaded full payloads under the authenticated identity and application user UUID plus engineering. Prefetch the latest five. Use per-account synthetic summary URLs so existing playback-position keys cannot collide between accounts. Offline admission requires the same saved Supabase identity and a previously API-confirmed user record in a separate Keychain item; new identities never enter via an outage. A definite denial clears that local admission and closes the reader. Transient outages preserve access only to that account's already saved data. The existing sign-in/invite flow remains the entry point; sign-out is available from reader settings.

## Review Focus

- Logout/account switching while list, content or TTS work is in flight must not resurrect old content/audio or write into the new account's cache.
- A new identity, revoked user, lost membership, malformed API envelope or repeated 401 must not be treated as offline success.
- Cold offline restart may read only previously admitted matching identity data; explicit logout cannot be undone by cached admission.
- The phone and CarPlay must share the same current reader and stop presenting/playing an old context immediately on logout.
- Legacy builds keep their behavior; pilot builds cannot silently reach GCS/Firebase feedback/push routes.

### Task 1: Authenticated feed client, disk cache and offline admission

**Files:** `EngPulse/Pilot/PilotAPIClient.swift`, `PilotAccountModel.swift`, new `PilotFeedReader.swift`; `PilotTests/PilotReaderTests.swift`, `PilotAccountTests.swift`, `PilotAPITests.swift`.
**Interfaces:** Generic authenticated `request(path:method:body:query:session:) -> Data` retains refresh-once and session-generation protection. `engineeringBriefs(session:) -> [PilotBriefSummary]` validates active membership before fetching at most 100 rows. `briefContent(date:session:) -> String` validates the engineering/date/V3 envelope and returns only its JSON payload. `PilotFeedReader` binds API/session/store, provides `summaries() -> (items, offline)`, `content(date:) -> String`, and synchronous `invalidate()`. Disk store is isolated by identity/user/feed; all asynchronous completion paths check the reader remains active and the session unchanged.

- [x] Write failing tests for correct endpoints/authorization, full payload extraction, membership/invalid envelope rejection, refresh-once behavior, cache replay, account isolation, late response after invalidation and denial without offline fallback.
- [x] Implement the smallest client/cache/reader changes, then make those tests green.
- [x] Test cold offline admission for an already-confirmed matching identity and deny new/different identities; test explicit logout and server denial invalidate cached admission. Implement and run the full Swift Package suite, then commit.

### Task 2: Connect the existing phone/CarPlay reader safely

**Files:** `AppServices.swift`, `EngPulseApp.swift`, `Services/{CacheService,ArticleContentLoader}.swift`, `Views/{PilotSignInView,DetailView,SettingsView}.swift`, `CarPlay/{CarPlaySceneDelegate,CarPlayContentManager}.swift`, Xcode project, focused `EngPulseTests`.
**Interfaces:** `PilotReaderContext` owns reader/scoped cache/AppState/TTS for one session; `AppServices` publishes its current context from account phase changes. A scoped CacheService content-loader override feeds the existing detail/TTS loader. AppState maps API summaries and honors invalidation. Phone/CarPlay use the same context and rebuild on changes.

- [x] Add regression tests for scoped caches/loader behavior and context invalidation, then implement routing to the existing ContentView for admitted sessions.
- [x] Wire reader settings sign-out, scope playback identity, stop/clear old context and hide legacy-only feedback/stats in pilot mode. Restore the same context on CarPlay and require phone sign-in when absent.
- [x] Run Swift Package tests, Xcode simulator tests and a signed device build. Preserve existing ignored signing/configuration files; do not change Apple/Supabase trust settings.

### Task 3: Release evidence and review

**Files:** Existing pilot plan/runbook/mobile README and PR #190 description.

- [ ] Verify PR #201 CI deployment, public health/freshness and the independent freshness workflow; retain production report references without secrets. Keep GCP dual-write/configuration unchanged.
- [ ] Record simulator/build and live API evidence; perform a real-device reader check when a device/session is available. A required human login is requested without collecting codes in chat.
- [ ] Run one fresh review of the final iOS branch, fix Important findings with failing regression tests, update PR #190 against main, and wait for CI. Do not claim full pilot launch or production notification readiness.
