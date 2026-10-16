# Multi-User Eng Pulse: Hetzner Pilot and Interest Feeds — Design

**Status:** Revised 2026-10-13 following Anton's direction: get the multi-user pilot live on Hetzner, retain the GCP pipeline, and handle OMGifts separately. This revision supersedes the 2026-09-01 rollout and cost assumptions.
**Next outcome:** About five invited iOS users can sign in, read/listen to the shared `engineering` brief, leave their own feedback, and receive notifications according to their preferences. Observe the pilot for 14 days before expanding.
**Execution plan:** [Hetzner multi-user pilot](../plans/2026-10-13-hetzner-multiuser-pilot.md). The [Phase 1 plan](../plans/2026-09-16-phase1-api-mvp.md) records the existing API implementation; it is not the pilot launch checklist.

## 1. Goals and constraints

- **Users:** about five invited iOS users first; 10–50 remains a later capacity goal.
- **Pilot feed:** one shared `engineering` feed, joined automatically on sign-up. Ordinary members cannot create feeds or edit sources/topics; enforce this in the API as well as the UI. Keep the existing pipeline source configuration authoritative; do not expose API edits that the pipeline does not consume.
- **Later feeds:** start with a few admin-approved interest feeds. Members subscribe and choose preferences; owners/admins manage configuration. Enable these flows only with working multi-feed generation, delivery, and spending limits. This is a shared community, not private team workspaces.
- **Identity:** Supabase Auth with Apple and email magic link/OTP plus an API invite gate. Google remains planned but does not block the iOS pilot. Keep identity separate from portable application data.
- **Hosting:** Hetzner for the API, Postgres, and notification worker. Retain Cloud Run, Cloud Scheduler, GCP model secrets, GCS artifacts, and the explorer job throughout the pilot. Full GCP exit is not a launch requirement or an assumed saving.
- **Backend:** Rust with shared contracts; use the existing Terraform/CI path. Retain Python functions while legacy clients/recipients need them.
- **Client:** Swift remains primary, preserving reading, offline use, TTS, and CarPlay. Native Kotlin/Compose Android follows a successful pilot under its own plan; Flutter remains archived.
- **Safety of rollout:** preserve the working daily pipeline, date-keyed replay behavior, and legacy reads. Never commit secrets. Record real scheduled-run and real-device evidence at launch gates.
- **Deferred:** additional feeds, self-service feed creation, Android, private workspaces, account linking, self-hosted identity, and GCP decommissioning. OMGifts cleanup is a separate task. Workflow engines, per-user generated briefs, a web app, and watch/Android Auto apps are outside the pilot.

## 2. Pilot architecture

```text
Supabase Auth ── JWT ──> Swift iOS ── authenticated requests ──> Hetzner
                                                            Caddy / TLS
                                                                 │
                                                            pulse-api
                                                                 │
                                                            Postgres
                                                                 │
                                                     notification outbox
                                                                 │
                                                       worker → email/APNs

GCP Cloud Scheduler → daily-agent (06:00 UTC, one engineering feed)
                         │                         │
                         ├─ GCS + manifest         └─ service-token POST to API
                         │
                         └─ existing clients / legacy notification recipients

GCS artifacts → import + scheduled reconciliation → API
Hetzner Postgres → nightly pg_dump → private GCS backup bucket
```

The pilot pipeline continues reading `config/sources.json`. API feed configuration becomes authoritative only in the later multi-feed phase. The pilot app switches reads after payload parity and reconciliation are proven; old builds continue reading GCS. The pipeline never connects directly to Postgres. Supabase supplies identity only; the API verifies JWTs locally against cached JWKS with issuer/audience pinned.

Continue the existing Rust API and portable Postgres on Hetzner. This is a product/operations choice, not a claim that Hetzner is cheaper than every GCP configuration. Avoid adding an identity or hosting migration to the pilot's critical path.

## 3. Data model and contracts

Existing Phase 1 schema (full columns/constraints remain in [the migration](../../../apps/pulse-api/migrations/0002_schema.sql)):

```text
users              id, email, display_name, is_admin
identities         user_id, issuer, subject; unique (issuer, subject)
invites            code, creator, max_uses, used_count, expires_at
feeds              id, slug, name, description, creator, is_active
feed_topics        feed_id, topic, added_by
feed_sources       feed_id, url, kind, added_by, is_active
memberships        user_id, feed_id, role, notify_email, notify_push
briefs             feed_id, date, format, payload, article metadata, model, eval_score
feedback           user_id, feed_id, date, aspect, value
device_tokens      user_id, platform, token, app_version, is_active
notifications_sent feed_id, date, user_id, channel, sent_at
runs               date, feed_id, status, token usage, estimated cost, error
```

Keep the existing uniqueness and foreign-key constraints. Briefs upsert on `(feed_id, date)`; feedback is scoped to `(user_id, feed_id, date, aspect)`; tokens have one active account owner. `identities` separates provider credentials from application users.

Preserve every original V3 JSON field/value through import, ingest, storage, and reads, including unknown fields. JSONB formatting/key order need not be byte-identical. Do not discard fields by decoding and re-encoding through a narrower struct. Add representative production fixtures and verify Swift decoding.

Add a durable `notification_outbox` in a new migration: unique `(feed_id, date, user_id, channel)`, state, attempt count, next-attempt time, lease expiry, and last error. Enqueue eligible work atomically with publication. `notifications_sent` records provider acceptance, not proof of delivery to a device. Record every billable model attempt separately from the latest successful daily run so retries do not disappear from cost reporting.

## 4. Auth, permissions, and account lifecycle

- Configure Supabase Apple and email/OTP with custom SMTP; verify a real invited user's sign-in and email delivery. Google/Kotlin follows later.
- Valid JWT without an identity gets `403 invite_required`. Sign-up consumes the invite, creates user/identity, and joins `engineering` in one transaction. Existing users retain their preferences on retries.
- Defer account linking. A matching email plus an invite is not sufficient to attach a different identity to an existing account. Reject collisions until an explicit verified linking flow exists; user-editable metadata is not proof of email ownership. The API readiness tranche enforces this rejection; real-provider verification remains a launch gate.
- `/v1/*` requires a registered user; `/internal/*` a service token; `/admin/*` an admin user. `/healthz` stays public. Enforce active account status, feed membership, feedback ownership, and device ownership server-side.
- During the pilot, only `engineering` is available for generation/subscription. Deny feed creation and source/topic mutation for all registered roles, including owners/admins. Admin source changes use the existing pipeline configuration workflow; HTTP configuration writes remain disabled.
- Scope cached lists, content, and pending feedback to the signed-in user/feed. Clear session state on logout; never submit a former account's pending feedback under a new account. Safely unregister/reassign a device through an explicit authenticated flow. Test account switching offline.
- Provide a documented admin procedure for revoking pilot access, cleaning up a departed user's records, and invalidating notification targets. Verify revoked access fails at the API, not just at sign-in.
- Firebase anonymous UIDs are not migrated. Preserve legacy feedback and backend compatibility. Remove Firebase Auth from the new Swift build once API feedback/device registration work. Provider migration/self-hosting requires a separate tested account/session migration.

## 5. Pipeline and data readiness

For the pilot, keep one daily `engineering` run on GCP with the existing prompts, models, sources, schedule, explorer job, and shadow policy. Additional feed generation and user-triggered model calls stay disabled.

Import the most recent 30 days of V3 briefs from GCS, without LLM calls or historical notifications. Add scheduled reconciliation for missed API writes, with bounded retries, a recorded checkpoint/outcome, and an alert when content remains behind. Warn-only dual-write alone is not a freshness guarantee. Verify complete payload/metadata parity and the next real scheduled run before switching app reads. Existing GCS/manifest writes continue.

Later multi-feed work can fetch the union of sources, isolate feed failures, and reuse compatible scrape/brief/judge results. Reuse keys include content, model, prompt version, and interests when generation depends on them. Keep current production providers unless a separately evaluated model change is requested. An upsert prevents duplicate rows, not repeated model charges; reuse artifacts during recovery and record every attempt.

Before expansion, enforce limits on active feeds, sources, input/output tokens, retries, and daily spend. Costs include per-feed selection plus distinct generated briefs/judging, shadow evaluation, exploration, and retries. The previous claim that cost depends only on distinct articles is withdrawn.

## 6. API and notifications

Keep the Phase 1 route groups for users, feeds, membership/preferences, briefs, feedback, devices, and internal ingest/run reporting. Gate unused creation/configuration routes during the pilot; exposing an endpoint is not a requirement to expose its UI.

| Group | Contract surface |
|---|---|
| `/v1` | `POST /users`, `GET /me`, `GET /feeds`, feed membership/preferences, `GET /feeds/{id}/briefs?before=`, `GET /briefs/{slug}/{date}`, `PUT /briefs/{slug}/{date}/feedback`, `PUT/DELETE /devices` |
| `/v1` gated mutations | Feed creation and topic/source additions/removals: unavailable to all pilot users, including admins/owners; later owner/admin access with working pipeline integration |
| `/internal` | `GET /feeds`, `POST /briefs`, `POST /runs`, `GET /feedback?feed=&since=`; service token required |
| `/admin` | Invite management and documented pilot access administration; admin identity required |

Add history/reconciliation and outbox behavior without changing the user-facing V3 rendering contract. Cursor-based brief pagination remains part of the API; the pilot does not require a new feed-management screen.

Pilot delivery uses email and APNs. A Postgres worker leases outbox work, rechecks active account status, membership/preferences and current device ownership before sending, bounds retries, and alerts on overdue/exhausted attempts. Invalid tokens are deactivated. External delivery is at least once: a crash after provider acceptance can cause a duplicate retry, so do not promise exactly-once email/push delivery. Repeated ingest must not create duplicate pending work or routinely resend accepted notifications.

Historical imports suppress notification creation. Reconciliation may enqueue a missed current-day delivery using the same unique key; older repairs stay silent. Record the behavior explicitly in the import/ingest interface and tests.

Before enabling pilot notifications, assign each pilot recipient/channel to exactly one sender and exclude it from the legacy path. Verify email recipients and APNs device registrations separately, retain the old path for remaining legacy recipients, and test rollback. Do not globally disable old notifications while older builds still need them. FCM is deferred with Android. The public GCS bucket remains available during the pilot.

## 7. Swift pilot

Target `https://api.eng-pulse.tsvetkov.org/v1` using Supabase JWTs. Ship sign-in/invite, the existing reading/TTS/CarPlay experience, personal feedback, email/push preferences, and APNs registration for `engineering`. Join new users automatically; verify their first screen contains a brief.

Account-aware caching and safe logout are required changes; the old instruction to leave `CacheService` unchanged is superseded. Test account A → logout → account B, expired tokens, offline restart, and queued feedback/device cleanup. Preserve useful offline reading within the correct account.

Keep feed creation and source/topic management out of the pilot UI. Add discovery/subscription and owner/admin configuration only when multi-feed generation and delivery pass end-to-end tests. Android receives its own later plan.

## 8. Hosting, operations, and recovery

- Existing stack: CX23, Ubuntu, 10 GB Postgres volume, Cloudflare DNS, Caddy, Docker Compose, GHCR releases. SSH is currently public for CI with key-only authentication; Terraform state remains in GCS.
- Terraform provisions; CI deploys. Keep deployment through existing main-branch workflows and production environment gates. Encode API-first ordering before enabling new pipeline/API integration; current independent jobs do not provide this guarantee.
- Runtime secrets stay outside Git and Terraform state. Use the existing GitHub production environment and GCP secret mechanisms. Verify configuration presence without recording values in evidence.
- Existing nightly cron runs `pg_dump` to the private GCS backup bucket with 30-day retention. Hetzner server snapshots exclude attached volumes; they are not a Postgres backup. [Hetzner volume documentation](https://docs.hetzner.com/cloud/volumes/overview/).
- Monitor external API health, engineering-brief freshness, reconciliation lag, notification backlog, disk space, and backup age. Reuse existing monitoring. A successful `/healthz` alone does not establish that users have today's brief.
- Pilot recovery targets: no more than 24 hours of lost database writes; restore service within two hours. Prove these with a timed isolated restore before invitations, including users/memberships/feedback and safe notification-worker recovery. Repeat quarterly.
- Document rollback of the app/API release and recipient/channel routing. Retain GCS artifacts and compatible legacy services; no project/resource teardown belongs to this pilot.

## 9. Delivery sequence

| Stage | Outcome and exit gate | GCP behavior |
|---|---|---|
| P0 Baseline | Reconfirm live state/configuration; record attributed hosting and model costs | Retained |
| P1 API readiness | Phase 1 corrections, identity setup, API-first deploy, seed, history import, reconciliation, successful restore | Daily/explorer jobs and artifact writes retained |
| P2 Complete pilot experience | Swift account flows and isolation plus durable email/APNs; two accounts on real devices; sender cutover and rollback proven | Legacy clients/recipients still work |
| P3 Live pilot | Invite about five users after P1/P2; observe 14 days; review usage, delivery, support effort, and actual costs | Retained throughout |
| Later: feeds | A few curated feeds, owner/admin controls, bounded generation, complete delivery | Jobs can stay on Cloud Run |
| Later: expansion | Android/self-service feeds/legacy retirement each need a separate plan | No automatic move to Hetzner cron |

Phase 1 API completion alone is not a multi-user launch. Use the [pilot plan](../plans/2026-10-13-hetzner-multiuser-pilot.md) for unchecked implementation tasks, dependencies, and launch evidence. Record build/CI identifiers, real scheduled-run results, and real-device checks at applicable boundaries.

## 10. Verification

- API integration tests on throwaway Postgres: authentication/invites, identity collisions, authorization, ownership, revocation, preferences, and pilot route restrictions.
- Contract/import tests: real production V3 shapes, preservation of unknown fields, silent history import, repeated ingest, and artifact replay without model calls.
- Failure tests: API unavailable during a scheduled run, reconciliation after recovery, worker restart/lease expiry, bounded notification retries, preference changes, invalid devices, and legacy/new sender isolation.
- Swift tests and real devices: sign-in, initial engineering membership/content, reading/TTS/CarPlay, feedback, notifications, logout/account switching offline, and token expiry.
- Production gates: seeded feed, real daily brief parity, actual email/APNs receipt, working legacy delivery, backup restoration, and exercised rollback. Retain evidence with the pilot plan; never store credentials or raw personal tokens.

## 11. Cost model and limits

- **User estimate, 2026-10-13:** GCP about £20/month overall, about £10 attributable to OMGifts. Roughly £10/month is the working Eng Pulse baseline, not an audited invoice. Claude/OpenAI spend is separate and must be measured. OMGifts cleanup is outside this plan.
- **Hetzner reference checked 2026-10-13:** CX23 €5.49/month + IPv4 €0.50/month, before VAT, the 10 GB volume, and backups. Verify the actual account tariff. Sources: [server pricing](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/), [IPv4 pricing](https://docs.hetzner.com/cloud/servers/primary-ips/overview/). Retire the former €5 all-in assumption.
- **Identity:** Supabase Free may cover pilot usage but can pause after inactivity; Pro starts at $25/month. Verify account tier and SMTP charges. Paid authentication must appear in the forecast. [Pricing](https://supabase.com/pricing).
- **Overlap:** report retained GCP, Hetzner, backup/storage, auth/SMTP, taxes, and model charges. Avoid double-counting storage already in the GCP invoice. Keep currencies separate until normalized from invoices. Do not assume migration savings during the pilot.
- **Model costs:** measure selection, generation, judging, shadow evaluation, exploration, and retries. Sharing one brief across five users should not multiply generation. The prior $15–30 ten-feed forecast is unvalidated and retired. V1/V2 retirement is already merged; do not count it again as a future saving.
- **Why retain jobs:** Cloud Run Jobs include a billing-account-wide free allowance; moving a short daily job alone may save little. [Cloud Run pricing](https://cloud.google.com/run/pricing).
- **Pilot controls:** one active generation feed, one scheduled daily publication, existing bounded retries, artifact reuse for recovery, no user-triggered LLM work. Record numeric hosting/model alert thresholds based on the verified baseline before invitations. Alerts do not cap spend; enforce generation limits before expanding feeds.
- Review the actual costs, maintenance effort, and engagement after 14 days. Additional feeds or job migration require evidence of value, affordability, and operating simplicity.

## 12. Repository and CI

Keep the monorepo: `libs/llm-client`, `libs/pulse-core`, `apps/daily-agent`, `apps/explorer-agent`, `apps/pulse-api`, `apps/mobile-swift`, `infra/hetzner`, legacy `functions`, and documentation. Android and `infra/gcp` work are deferred.

Use the single path-filtered workflow: Rust formatting/clippy/unit tests; database-backed API tests in `api-it`; contract fixture drift; Swift checks; Terraform validation/plans; Python tests while legacy functions remain. Add focused tests for pilot changes. On main, CI deploys agents/API/functions and gates infrastructure/production actions as configured. Make API/agent ordering explicit before the integration cutover. Mobile distribution continues through Xcode/TestFlight.

## 13. Deferred roadmap

After the pilot review: curated multi-feed generation and subscriptions, then self-service feed creation if justified; Android; private team spaces; explicit account linking; self-hosted auth; separate model experiments; explorer proposals to feed owners; GCP consolidation/retirement. OMGifts remains a separate task. Pilot freshness, notification, and backup alerts are required now.
