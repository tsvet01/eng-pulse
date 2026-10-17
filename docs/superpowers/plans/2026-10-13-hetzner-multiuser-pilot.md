# Hetzner Multi-User Pilot — Delivery Plan

**Updated:** 2026-10-17. **Status:** API/admin access and 29-brief production history verified; scheduled repair implemented for review, with deployment and launch gates remaining.
**Goal:** About five invited iOS users use the shared engineering brief through the Hetzner API, with sign-in, offline reading/TTS, personal feedback, and reliable email/APNs preferences. Observe 14 days before expanding.
**Design:** [Multi-user design](../specs/2026-09-01-multiuser-cohorts-design.md).
**Baseline implementation:** [PR #185](https://github.com/tsvet01/eng-pulse/pull/185), branch `plan/phase1-api-mvp`, plus its [historical implementation plan](2026-09-16-phase1-api-mvp.md).

## Scope and decisions

- Keep the GCP daily/explorer jobs, schedules, models/prompts, secrets, GCS artifacts, and manifest behavior. Add/reliably operate the API mirror; do not migrate job execution to Hetzner.
- Use the existing Hetzner API/Postgres infrastructure and Supabase identity. First release: Apple and email/OTP. Google is a later addition unless already working without delaying the pilot.
- Use `org.tsvetkov.eng-pulse` for the pilot iOS app (Anton, 2026-10-13); keep the display name **Eng Pulse**. Complete Apple registration/signing, Supabase audience setup, Firebase removal or matching configuration, and new APNs routing before distribution. Preserve the legacy GCP sender and old app identity. See [app identity setup](../../runbooks/phase0-setup.md#pilot-app-identity).
- Offer one shared `engineering` feed. Join it during sign-up; ordinary users cannot create feeds or edit sources/topics. Enforce the restriction server-side. API configuration edits must not pretend to change the existing GCS-configured pipeline.
- Complete notification delivery and account isolation before inviting external users. API endpoint coverage alone is not launch readiness.
- Retain old clients and notification recipients through an explicit compatibility period. Cut over pilot recipients individually, with rollback.
- Defer extra feeds, Android, self-service feed creation, private workspaces, identity self-hosting, and GCP retirement. OMGifts cleanup is a separate task and has no tasks or dependencies here.

## Evidence at the start

Snapshot from the 2026-10-13 review; recheck before deployment:

| Area | Observed state | Implication |
|---|---|---|
| Hetzner | Public `/healthz` returned 200 with `status=ok, db=ok`; `/internal/feeds` returned 404 | Infrastructure/API skeleton live; Phase 1 routes not deployed |
| API MVP | PR #185 open at `6b87ca3`; Rust, API integration, fixtures checks green | Reuse implementation; do not rebuild it from scratch or infer launch readiness from CI |
| GCP artifacts | Public manifest included the 2026-10-13 brief | Preserve the working publication path |
| Deployment | September API job pending; Terraform apply waiting | Review current outstanding jobs and revisions before any release |
| Configuration | PR/runbook records Supabase project and pipeline-secret setup as prerequisites | Presence and correctness not independently verified; inspect without exposing values |
| Costs | User estimates £20/month GCP, roughly £10 for OMGifts | Working Eng Pulse baseline roughly £10/month, excluding model charges; verify attribution |

## P0 — Establish the release baseline

**Owner:** implementer for code/evidence; Anton for account configuration and existing production deployment approvals.

- [ ] Record latest main/PR revisions, CI results, deployed API revision, and outstanding deployment jobs. Work from the current Phase 1 branch rather than the stale root checkout; preserve unrelated mobile edits.
- [ ] Verify Supabase project/tier, Apple + email/SMTP setup, issuer/audience/JWKS, admin identity, and matching pipeline service-token configuration/access. Use [Phase 1 setup](../../runbooks/phase1-setup.md); record status only, never secret values.
- [ ] Attribute Eng Pulse hosting and LLM charges for the most recent complete billing period. Record Hetzner, retained GCP, backup/storage, auth/SMTP, taxes, model charges, and operating effort separately. Set numeric hosting and model alert thresholds; include the temporary overlap and any paid auth tier.
- [ ] Record current deployed image references and legacy recipient/channel routing for rollback. Define the five intended pilot accounts without storing private credentials in the repository.

**Exit:** a known release/configuration baseline and cost worksheet. No cloud resource teardown is required.

**Reconciliation release evidence, 2026-10-17:** [PR #201](https://github.com/tsvet01/eng-pulse/pull/201) merged as `fc696f6`. [API deployment 39053276469](https://github.com/tsvet01/eng-pulse/actions/runs/39053276469) succeeded after its production approval. Public `/healthz` reported API/database healthy; `/healthz/briefs` returned `status=ok, reason=current`. The independent [freshness run 39053925514](https://github.com/tsvet01/eng-pulse/actions/runs/39053925514) also succeeded on this revision. GCP daily/explorer jobs were not redeployed by this API-only release; their existing schedule and publication remain running, and dual-write remains off. Actual failure-alert receipt, the next 06:00 UTC publication parity and the controlled outage rehearsal remain unverified.

## P1 — Make the API ready for real readers

### 1. Close the pilot's API gaps

**Targets:** `apps/pulse-api/src/{auth,db,routes}`, migrations/tests, `libs/pulse-core`, and `apps/daily-agent/src/api_client.rs`.

- [x] Reject email collisions with another identity, even with a valid invite; test reader/admin collisions with signed test identities and verify invite rollback. Two-provider real sign-in remains part of the API access launch gate; explicit account linking stays deferred.
- [x] Expose only active engineering to readers/internal consumers. Reject feed creation and source/topic writes for every registered role, including owners/admins, through HTTP. Admin configuration uses the existing pipeline workflow; owner editing is deferred with extra feeds.
- [x] Join engineering atomically with signup/invite consumption; missing/inactive seed rolls everything back. HTTP/DB tests verify fresh-user reading, per-account feedback, retry preferences/departure, and device ownership. Add per-request account disabling and the [operator revocation procedure](../../runbooks/phase1-setup.md#revoke-pilot-access--departure). Real-device checks remain gated below.
- [x] Preserve complete V3 JSON through mapper, ingestion, JSONB, and reads. Cover unknown/nested fields, optional nulls and omissions, metadata, and double-precision scores. Regenerate fixtures and decode with the actual Swift model; verify today's published V3 shape too.

**Exit:** focused authorization/contract tests and the existing CI checks pass on the release revision. This stage does not add new generation behavior.

**Verification, 2026-10-13:** 205 Rust tests pass against disposable Postgres 18.6; workspace/all-target Clippy with warnings denied and rustfmt pass. Swift contract checks pass for generated full/minimal fixtures and the public 2026-10-13 GCS brief. Fixture regeneration is deterministic. Actionlint reports the same two pre-existing shellcheck findings (SC2034/SC2129) as the original PR; the added Swift check has none. [Remote CI on API-readiness commit `cc743150`](https://github.com/tsvet01/eng-pulse/actions/runs/38464754868) passed Rust, API integration, fixtures and Swift checks; deployment jobs were skipped. The subsequent bundle ID rename has passed local project/plist validation but still needs CI and signed-device validation.

**Supabase configuration, verified 2026-10-13:** Project `zimjnykjqsxwsidwmemd` is healthy in Frankfurt (`eu-central-1`) on the Free plan; its current signing key is ECC P-256/ES256 and its public JWKS publishes that key. Email and email confirmation are enabled. Apple is enabled but has the team ID instead of the app bundle ID; the correction is not saved. Anton saved Resend SMTP credentials directly in Supabase; enabled SMTP and stored password were verified. Sender `Eng Pulse <eng-pulse@n21.me>` uses the verified `n21.me` domain. Signup and sign-in templates now show one-time codes, with saved content verified. Admin email confirmed as `anton.tsvetkov@gmail.com`. Email and token test results are below; production secret installation remains open. GCP and Hetzner configuration are unchanged.

**Email test result, 2026-10-14:** Exactly two authorized emails were delivered: [signup](https://resend.com/emails/01a138ea-dbbe-7b20-9bb2-09a439a1e537) and [repeat sign-in](https://resend.com/emails/01a138f8-613f-76b6-be36-4b04cff13112). Anton entered both codes locally; both were accepted. Both ES256 signatures verified against the project JWKS, with matching issuer/audience, valid expiry and confirmed administrator email. Both temporary test sessions were signed out. No API membership or administrator role was created by this test. Apple configuration, production secret installation, deployed API authorization and Swift launch gates remain open.

**Apple setup, 2026-10-14:** With Anton's confirmation, registered `org.tsvetkov.eng-pulse` under team `9XQ7BW6Q4T`, with Sign in with Apple (primary App ID) and Push Notifications. Apple Developer lists the new identifier alongside both legacy app IDs. With separate explicit approval, replaced the incorrect team ID in Supabase Apple Client IDs with `org.tsvetkov.eng-pulse`; persistence verified after a page reload. The Apple provider remains enabled and allowing users without an email remains off. This supersedes the unsaved Apple configuration noted on 2026-10-13. CarPlay authorization, provisioning and native signed-device sign-in remain open.

**App Store Connect, verified 2026-10-15:** Anton had completed the terms step. Refreshing the stale tab cleared the agreement screen and the Apps page opened normally, showing **No Apps** for the current account. The agreement is no longer a blocker; create an Eng Pulse app record for `org.tsvetkov.eng-pulse` before TestFlight distribution.

### 2. Deploy and reconcile the API mirror

**Targets:** `.github/workflows/ci.yml`, API import/reconciliation command and tests, daily-agent integration, [Phase 1 runbook](../../runbooks/phase1-setup.md).

- [x] Encode API-first deployment readiness in CI before enabling the agent integration; keep unrelated agent-only releases independent. Check seeded/authenticated `/internal/feeds` as well as `/healthz`. Do not rely on manually racing the existing independent jobs.
- [ ] Through the existing release process, deploy API migrations, seed `engineering` and the initial invite, verify the correct API revision/token, then enable/verify GCP dual-write. Keep fan-out off until P2 sender routing is ready. If seeding follows deployment, keep the integration disabled until the seed is confirmed.
- [x] Implement idempotent import of the latest 30 days of existing V3 GCS artifacts and metadata. Import must make zero LLM calls and send zero historical notifications. Compare expected dates/counts and complete JSON values with API records; record any source gaps explicitly.
- [x] Implement and deploy scheduled reconciliation for Hetzner, with a documented bounded interval/retry policy and last-success status. Use narrowly scoped GCS access or the existing public artifacts; do not broaden the backup credential. Reconcile missed writes without regenerating briefs. Old repairs stay silent; current-day recovery uses the notification idempotency key once P2 is enabled.
- [ ] Exercise an API outage: the GCP run still publishes GCS/manifest; after recovery reconciliation restores the missing API brief. Verify repeat reconciliation preserves payloads and never adds duplicate publications or notifications.
- [ ] Observe the next real 06:00 UTC run and compare GCS/API content, metadata, and timestamp. Smoke success alone is insufficient.

**Exit:** current and recent history are available through the API, recovery is demonstrated, and the working GCP publication path remains intact.

**Release-guard implementation, 2026-10-15:** Integration defaults off unless the repository Actions variable `PULSE_API_ENABLED` is exactly `true`. Combined releases wait for successful API deployment; agent-only releases allow a skipped API job, and explicit dispatch runs the required tests. Enabled releases verify database health, the actual GCP service token and exactly the active engineering feed before any build/job mutation. The daily job's image/environment/secrets update together; no preliminary credential clearing occurs. Smoke validation rejects empty/inactive/wrong feeds. Regression tests exercise real HTTP requests against a local server with a recording cloud CLI, including the disabled path, bad tokens/routes, missing seeds and build failures. These guards must be included in #185 before its main-branch release; deployment/seed/activation remain operator steps in the [Phase 1 runbook](../../runbooks/phase1-setup.md). No cloud changes are made by this implementation.

**Release evidence, 2026-10-16:** PR #185, including release guards and safe public Supabase configuration, merged as `1d90f17`. [CI run 38971413771](https://github.com/tsvet01/eng-pulse/actions/runs/38971413771) completed successfully: API deployment, daily/explorer GCP updates and real-provider smoke passed. Public API checks returned healthy API/database and 401 for an unauthenticated account request. Private production credentials were retained; API integration remains default-off. Native Apple sign-in and Supabase email/OTP delivery were verified earlier. This is API deployment evidence, not authenticated API admission or pilot launch.

**Setup evidence, 2026-10-17:** [PR #196](https://github.com/tsvet01/eng-pulse/pull/196) added the guarded manual bootstrap. [Pilot setup run 39018382733](https://github.com/tsvet01/eng-pulse/actions/runs/39018382733) passed all 29 release-script tests and verified the existing API revision, database health, service-token access, active engineering sources and private single-use invite. Real Supabase email/OTP sign-in then returned initial `/v1/me` 403 `invite_required`, signup 201, and subsequent account/feed reads 200 with administrator status and engineering membership. The feed had 50 active sources and an empty brief list at this setup checkpoint; the later history import below populated it. The temporary verification session was signed out locally. No GCP activation or container restart occurred. Reconciliation deployment, GCP activation, reader migration, recovery and notifications remain required gates.

**History import implementation, 2026-10-17:** The `import-history` API command and guarded `Pilot history import` workflow are prepared for the first 30-day load. They preserve complete JSON/metadata, verify stored parity atomically, leave personal state unchanged, and send no historical notifications or model requests. Conflicting existing records require review instead of automatic replacement. The public source currently contains 29 briefs for 18 September–17 October; 10 October is absent from both manifest and artifact storage. Local validation passed 61 API tests and 33 release-script tests. A real public-source import into disposable Postgres inserted and verified all 29 briefs; replay inserted zero and verified 29 unchanged. Downloads are pinned to exact object generations and reject artifacts created at or after the manifest version. Production import/replay evidence is recorded below. Reconciliation activation, delivered freshness alerts, GCP integration activation and real daily-run parity remain open.

**Production history and release evidence, 2026-10-17:** [Import run 39029673324](https://github.com/tsvet01/eng-pulse/actions/runs/39029673324) inserted 29 and verified 29; [replay 39029793870](https://github.com/tsvet01/eng-pulse/actions/runs/39029793870) inserted zero and verified 29 unchanged. The source gap is 10 October. [PR #200](https://github.com/tsvet01/eng-pulse/pull/200) merged as `80e2a88`; [release run 39029761694](https://github.com/tsvet01/eng-pulse/actions/runs/39029761694) passed API/agent deployment and real-provider smoke. GCP daily/explorer remain running; API dual-write remains off.

**Scheduled repair implementation:** See the [reconciliation slice](2026-10-17-pilot-reconciliation.md) and [operating procedure](../../runbooks/phase1-setup.md#scheduled-repair-and-freshness). The opt-in API worker checks public artifacts on startup and every 15 minutes, persists bounded attempts/last success, serializes replicas, and repairs silently. A minimal public probe checks the worker checkpoint and current source/database dates; an hourly independent Actions job fails if freshness is unconfirmed. Deployment and live freshness passed as recorded below. Actual alert receipt, the next scheduled GCP run and a production outage rehearsal still need evidence.

### 3. Prove recovery and operational visibility

**Targets:** `infra/hetzner/files/backup.sh`, runtime configuration, monitoring/runbooks. Change code only where the checks expose a gap.

- [ ] Confirm successful nightly database backup and off-host retention; alert on backup age/failure and disk pressure. Server snapshots do not include the attached Postgres volume.
- [ ] Restore into an isolated database and time the procedure. Verify users, identities, memberships, feedback, brief counts/payloads, and pending/sent notification state. Start restored workers with delivery disabled; reconcile routing and provider acceptance before resuming to avoid historical resend.
- [ ] Demonstrate the pilot recovery targets: at most 24 hours of lost database writes and service recovery within two hours. Record measured results and fix gaps before invitations.
- [ ] Verify external health and API content-freshness alerts, reconciliation failure/lag, and notification backlog/failure alerts. Record exact thresholds and destinations. Test one alert for each failure class.
- [ ] Exercise rollback to the prior API image and compatible client behavior. Keep migrations compatible with the prior image or document a tested forward repair. Do not assume GCS restores user feedback/account state.

**Exit:** dated restore/alert/rollback evidence. `/healthz` alone does not satisfy this gate.

## P2 — Complete the user experience before invitations

Swift work and the delivery worker may be developed independently after the API contract is stable; both must pass before P3.

### 4. Swift sign-in and personal state

**Targets:** `apps/mobile-swift` auth/onboarding, API/feedback/device/cache services, settings, and focused tests.

- [ ] Add Apple and email/OTP sign-in, invite acceptance, token refresh/expiry handling, and automatic engineering membership. No feed creation or source/topic editing UI in this release.
- [ ] Read lists/briefs from the API and send feedback under the current account. Preserve reading, offline use, TTS, and CarPlay; use the imported history so switching does not present an empty library.
- [ ] Scope caches and pending feedback to account/feed. Test A → logout → B with no network, queued writes, expired tokens, and app restart. Never display A's personal state or submit A's queued writes as B. Clear active session state on logout.
- [ ] Implement safe device logout/account switching, including queued cleanup when offline and server-side ownership checks. Re-evaluate notification targets when the account changes. Remove the new build's Firebase Auth path only after API feedback/device registration works.
- [ ] Provide email/push preferences and verify opt-out on actual delivery. Document admin revocation and data cleanup for someone leaving the pilot.

**Swift checkpoint, 2026-10-15:** Added a separate pilot entry flow for the renamed bundle, with native Apple nonce exchange, email OTP, Keychain storage, refresh, invite admission and sign-out. The client rejects responses from old sessions and distinguishes an API outage from missing or revoked access. The renamed app cannot call legacy Firebase feedback/device paths or load old reader caches. This is a development checkpoint: an admitted account sees an explicit readiness message; reading/audio/notifications are not enabled. Firebase remains available only to an explicit legacy build. Supabase session signup alone is not API membership.

**Local validation:** Authentication/admission tests cover expired/rejected refresh, stale responses after logout, malformed sessions, invalid invites, disabled users and API outage. The iOS simulator build passes; Keychain save/update/removal and build-setting injection pass with local ad-hoc signing. The full local suites pass: 25 authentication/admission tests and 54 iOS tests. Fresh review found a multi-window session ownership gap; a failing regression test reproduced it, and the shared app-wide session owner plus delayed Apple callback checks now pass. Native Apple sign-in passed the physical-device check below; live API admission and the full two-account offline reader journey remain pending. No cloud deployment, GCP pipeline changes or additional sign-in emails occurred.

**Device test, 2026-10-15:** Development provisioning now supports Apple sign-in and push for the new bundle. The complete entitlement set still fails because CarPlay is not authorized. A local authentication-only build, using a temporary entitlement override without CarPlay, compiled and passed strict signature verification with the correct identity and Supabase configuration. The repository's entitlements are unchanged. Pairing, installation and launch on an iPhone 14 Pro succeeded. Anton completed Apple's prompt and reported “You’re signed in; pilot access still needs confirming.” Native Apple-to-Supabase authentication passed; API admission, membership and administrator access are not verified. NordVPN's temporarily relaxed local-device isolation was restored after launch and its connected state verified. Full CarPlay provisioning remains a release gate.

**Reader implementation, 2026-10-17:** The [iOS reader slice](2026-10-17-ios-pilot-reader.md) connects admitted accounts to the Hetzner engineering list and complete V3 payloads. Phone and CarPlay use one session-bound reader and audio context; downloaded articles, audio and playback identities are scoped by Supabase identity/API user/feed. Existing admitted identities can read saved data offline, while first-time identities and definite server denials cannot enter via an outage. Sign-out closes old screens and permanently stops the old player. Pilot feedback and notification controls remain hidden until those API flows are implemented. GCP and explicit legacy builds are unchanged.

**Reader validation, 2026-10-17:** 37 Swift Package tests and 60 iOS simulator tests pass, including refreshed-token failures, late responses, cached admission, account isolation, scoped content routing and playback shutdown. The signed development phone build passes signature/bundle/configuration checks using the existing temporary override without CarPlay; the full entitlement build still fails on Apple's unapproved CarPlay entitlement. The newly connected iPhone needs inclusion in the development profile before installation. Live phone reading and the two-account journey are not yet claimed.

### 5. Durable notifications and controlled sender cutover

**Targets:** a new API migration, publication/outbox DB code, a small Rust worker, Compose configuration, and recipient filtering in legacy functions where needed.

- [ ] Atomically enqueue one delivery record per `(feed, date, user, channel)` with eligible brief publication. Suppress historic imports; repeated ingestion must not routinely resend accepted notifications.
- [ ] Implement worker leases, bounded backoff/retries, attempt/error records, and exhausted-attempt alerts. Recheck active account status, membership, preferences, current device owner, and token validity before sending. Do not fail brief storage because SMTP/APNs is temporarily unavailable.
- [ ] Test worker restart/lease expiry, concurrent workers, transient/permanent provider failures, invalid device tokens, opt-out while pending, and replay. Document the crash-after-provider-acceptance window: delivery is at least once, not guaranteed exactly once.
- [ ] Establish per-recipient/channel routing: disable legacy sending to the pilot recipient/device before enabling its new sender. Verify a remaining legacy recipient still receives delivery. Keep rollback instructions to turn off the new sender and restore the legacy route without replaying old notifications.
- [ ] On two real accounts/devices, demonstrate actual email/APNs receipt, preference changes, logout/account switching, and the next real daily brief. Provider acceptance logs alone do not establish user receipt.

**P2 exit:** one complete daily journey works for two distinct accounts on real devices, with no cross-account state or routine duplicate notifications and a verified rollback path. External invitations remain gated on P1 and P2 evidence.

## P3 — Invite and observe

- [ ] Invite approximately five users through the existing product process after P1/P2 gates pass. Record the deployed API revision and distributed iOS build. Do not expand generation beyond engineering.
- [ ] Observe 14 consecutive calendar days: API brief freshness, notification attempts/acceptance and reported receipt, failures/recovery, reads/listens, feedback, weekly active users, user-reported problems, cloud/model spend, and time spent operating the service. Use minimal aggregate telemetry; do not collect article text or credentials for analytics.
- [ ] Investigate every missing daily brief/delivery; measure recovery and remaining gaps. Treat empty feedback as feedback about usefulness rather than a reason to add features automatically.
- [ ] At day 14, record a continue/fix/expand decision. Expand only after account-isolation issues are absent, recurring delivery failures are resolved, costs are understood within the recorded thresholds, and pilot users demonstrate value. Usage targets are learning metrics, not invented claims of success.

## Launch evidence

Fill this table during execution; unchecked tasks and blank evidence mean the gate is open. Keep personal data and secret values out of the record.

| Gate | Required evidence | Result / date / reference |
|---|---|---|
| Baseline | Revisions, CI, config presence, attributed cost worksheet and thresholds | Pending |
| API access | Real sign-in/invite, engineering membership, ownership/revocation checks | Admin email/OTP admission and engineering membership verified 2026-10-17; native Apple sign-in previously verified. Second-account and real ownership/revocation checks remain open. |
| Data | History parity, next scheduled run, outage + reconciliation proof | 29 production briefs verified, replay inserted zero (2026-10-17). Reconciliation deployed and live freshness current (2026-10-17); scheduled-run parity and production outage proof pending. |
| Recovery | Timed restore, alert tests, rollback procedure/results | Pending |
| Swift | Two-account real-device checks, offline account switching, TTS/CarPlay | Sign-in/admission checkpoint simulator-tested and native Apple sign-in verified on one iPhone 2026-10-15; reader migration, two-account journey and CarPlay gates pending |
| Delivery | Actual email/APNs receipt, preferences, retry/replay and legacy isolation | Pending |
| Pilot launch | All above passed; release/build IDs and about five users onboarded | Pending |
| Pilot review | 14-day usage, reliability, cost, operating effort, decision | Pending |

## After the pilot

1. Add a few curated feeds only when multi-feed generation, owner/admin permissions, source validation, and end-to-end delivery ship together. Set numeric feed/source/token/retry/daily-cost limits before activation; record every model attempt and reuse compatible artifacts.
2. Consider self-service feeds and Android based on observed demand. Private workspaces and account linking need explicit separate designs.
3. Revisit job hosting or legacy retirement only if measured cost or operational simplicity justifies it. Retained GCP jobs, backup storage, and Terraform state are acceptable outcomes. OMGifts cleanup remains separate.
