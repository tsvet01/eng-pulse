# Hetzner Multi-User Pilot — Delivery Plan

**Updated:** 2026-10-13. **Status:** first API readiness tranche implemented and locally verified; deployment and launch gates remain open.
**Goal:** About five invited iOS users use the shared engineering brief through the Hetzner API, with sign-in, offline reading/TTS, personal feedback, and reliable email/APNs preferences. Observe 14 days before expanding.
**Design:** [Multi-user design](../specs/2026-09-01-multiuser-cohorts-design.md).
**Baseline implementation:** [PR #185](https://github.com/tsvet01/eng-pulse/pull/185), branch `plan/phase1-api-mvp`, plus its [historical implementation plan](2026-09-16-phase1-api-mvp.md).

## Scope and decisions

- Keep the GCP daily/explorer jobs, schedules, models/prompts, secrets, GCS artifacts, and manifest behavior. Add/reliably operate the API mirror; do not migrate job execution to Hetzner.
- Use the existing Hetzner API/Postgres infrastructure and Supabase identity. First release: Apple and email/OTP. Google is a later addition unless already working without delaying the pilot.
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

## P1 — Make the API ready for real readers

### 1. Close the pilot's API gaps

**Targets:** `apps/pulse-api/src/{auth,db,routes}`, migrations/tests, `libs/pulse-core`, and `apps/daily-agent/src/api_client.rs`.

- [x] Reject email collisions with another identity, even with a valid invite; test reader/admin collisions with signed test identities and verify invite rollback. Two-provider real sign-in remains part of the API access launch gate; explicit account linking stays deferred.
- [x] Expose only active engineering to readers/internal consumers. Reject feed creation and source/topic writes for every registered role, including owners/admins, through HTTP. Admin configuration uses the existing pipeline workflow; owner editing is deferred with extra feeds.
- [x] Join engineering atomically with signup/invite consumption; missing/inactive seed rolls everything back. HTTP/DB tests verify fresh-user reading, per-account feedback, retry preferences/departure, and device ownership. Add per-request account disabling and the [operator revocation procedure](../../runbooks/phase1-setup.md#revoke-pilot-access--departure). Real-device checks remain gated below.
- [x] Preserve complete V3 JSON through mapper, ingestion, JSONB, and reads. Cover unknown/nested fields, optional nulls and omissions, metadata, and double-precision scores. Regenerate fixtures and decode with the actual Swift model; verify today's published V3 shape too.

**Exit:** focused authorization/contract tests and the existing CI checks pass on the release revision. This stage does not add new generation behavior.

**Local verification, 2026-10-13:** 205 Rust tests pass against disposable Postgres 18.6; workspace/all-target Clippy with warnings denied and rustfmt pass. Swift contract checks pass for generated full/minimal fixtures and the public 2026-10-13 GCS brief. Fixture regeneration is deterministic. Actionlint reports the same two pre-existing shellcheck findings (SC2034/SC2129) as the original PR; the added Swift check has none. Remote CI must run on the pushed revision. Full iOS simulator/device validation is still separate from the standalone decoder check.

**Supabase evidence:** Anton supplied project `zimjnykjqsxwsidwmemd`; its public JWKS publishes ES256/P-256. Admin email confirmed as `anton.tsvetkov@gmail.com`. Provider/SMTP settings, current-token algorithm, region/tier and production secret installation still need verification; no cloud configuration was changed by this tranche.


### 2. Deploy and reconcile the API mirror

**Targets:** `.github/workflows/ci.yml`, API import/reconciliation command and tests, daily-agent integration, [Phase 1 runbook](../../runbooks/phase1-setup.md).

- [ ] Encode API-first deployment readiness in CI before enabling the agent integration; keep unrelated agent-only releases independent. Check seeded/authenticated `/internal/feeds` as well as `/healthz`. Do not rely on manually racing the existing independent jobs.
- [ ] Through the existing release process, deploy API migrations, seed `engineering` and the initial invite, verify the correct API revision/token, then enable/verify GCP dual-write. Keep fan-out off until P2 sender routing is ready. If seeding follows deployment, keep the integration disabled until the seed is confirmed.
- [ ] Implement idempotent import of the latest 30 days of existing V3 GCS artifacts and metadata. Import must make zero LLM calls and send zero historical notifications. Compare expected dates/counts and complete JSON values with API records; record any source gaps explicitly.
- [ ] Implement scheduled reconciliation on Hetzner, with a documented bounded interval/retry policy and last-success status. Use narrowly scoped GCS access or the existing public artifacts; do not broaden the backup credential. Reconcile missed writes without regenerating briefs. Old repairs stay silent; current-day recovery uses the notification idempotency key once P2 is enabled.
- [ ] Exercise an API outage: the GCP run still publishes GCS/manifest; after recovery reconciliation restores the missing API brief. Verify repeat reconciliation preserves payloads and never adds duplicate publications or notifications.
- [ ] Observe the next real 06:00 UTC run and compare GCS/API content, metadata, and timestamp. Smoke success alone is insufficient.

**Exit:** current and recent history are available through the API, recovery is demonstrated, and the working GCP publication path remains intact.

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
| API access | Real sign-in/invite, engineering membership, ownership/revocation checks | Pending |
| Data | History parity, next scheduled run, outage + reconciliation proof | Pending |
| Recovery | Timed restore, alert tests, rollback procedure/results | Pending |
| Swift | Two-account real-device checks, offline account switching, TTS/CarPlay | Pending |
| Delivery | Actual email/APNs receipt, preferences, retry/replay and legacy isolation | Pending |
| Pilot launch | All above passed; release/build IDs and about five users onboarded | Pending |
| Pilot review | 14-day usage, reliability, cost, operating effort, decision | Pending |

## After the pilot

1. Add a few curated feeds only when multi-feed generation, owner/admin permissions, source validation, and end-to-end delivery ship together. Set numeric feed/source/token/retry/daily-cost limits before activation; record every model attempt and reuse compatible artifacts.
2. Consider self-service feeds and Android based on observed demand. Private workspaces and account linking need explicit separate designs.
3. Revisit job hosting or legacy retirement only if measured cost or operational simplicity justifies it. Retained GCP jobs, backup storage, and Terraform state are acceptable outcomes. OMGifts cleanup remains separate.
