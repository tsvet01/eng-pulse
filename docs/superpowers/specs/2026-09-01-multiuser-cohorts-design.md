# Multi-User Eng Pulse: Auth, Interest Feeds, Hetzner Tier — Design

**Status:** Approved in-session 2026-09-01 (brainstorm with Anton, sections 1–8).
**Scope:** Turn the single-user pipeline into an invite-only multi-user product with interest-based feeds ("cohorts"), real sign-in, per-user notifications, an Android app, and a self-owned hosting tier — without ever breaking the working daily pipeline.

## 1. Goals and constraints

- **Users:** friends & colleagues, ~10–50 in year one, invite-gated.
- **Cohorts = interest feeds:** anyone can create/join a feed; each feed has its own sources and topics; members add/remove both; one brief per feed per day.
- **Sign-in:** Sign in with Apple, Google, email magic link — plus invite codes on top.
- **Firebase:** shrink to the unavoidable minimum (FCM for Android push). Identity and data must be portable; no Firestore.
- **Hosting:** Hetzner for the new tier (fun, owned, flat cost); GCP pipeline stays until the new tier is proven.
- **Language:** Rust for all backend code (shared types with the pipeline; the Python cloud functions retire).
- **Clients:** Swift iOS stays primary; **native Kotlin/Compose** for Android (premium bar: background TTS, lock-screen controls, Android Auto later). Flutter app is archived.
- **Infra as code:** Terraform for the Hetzner tier and Cloudflare DNS; later import of click-ops GCP resources.
- **Non-negotiables:** keep the daily pipeline idempotent and replay-safe; never commit secrets; every phase ends with a real run and a real device.
- **Out of scope (this spec):** Temporal or any workflow engine; per-user personalized briefs (feeds are shared); web app (`eng-pulse.tsvetkov.org` reserved); watch app; Android Auto (later phase of the Android project).

## 2. Architecture

```
                        ┌──────────────────── Hetzner VPS (Terraform) ───────────────────┐
                        │  Caddy (TLS) → pulse-api (Rust/axum) → Postgres 16 (+ nightly   │
                        │  pg_dump → private GCS bucket)                                   │
                        │  Serves: JWT-authed reads/writes for apps; /internal for the     │
                        │  pipeline; /admin for the owner. Sends email + FCM + APNs.       │
                        └──────────────▲────────────────────────────▲─────────────────────┘
                                       │ Bearer Supabase JWT         │ Bearer service token
              ┌────────────┐           │                             │
  Sign-in ───▶│  Supabase   │──JWTs───▶│                 ┌───────────┴───────────┐
  (Apple /    │  Auth       │      ┌───┴────┐            │ daily-agent (Rust)    │
   Google /   │  (managed;  │      │ Swift  │            │ Cloud Run Job 06:00Z  │
   magic link)│  self-host  │      │ Kotlin │            │ loops over feeds      │
              │  exit path) │      │ apps   │            │ (dual-writes GCS      │
              └────────────┘      └────────┘            │  during transition)   │
                                                         └───────────────────────┘
```

Principles: GCS is demoted from "the database" to a pipeline artifact store; the read path moves behind an authenticated API; the pipeline never talks to Postgres directly (reads feed config from the API, posts briefs back), so it can run anywhere; Supabase is an identity provider only (no data), verified locally via JWKS.

Alternatives considered and rejected: Supabase-as-whole-backend (fewest moving parts but deepest vendor embrace, RLS as the security model, no Hetzner/Rust fit); GCP-native with Firestore (cheapest at 50 users, but the proprietary path); full self-host from day one (two risks at once).

## 3. Data model (Postgres)

```sql
users        (id uuid PK, email citext UNIQUE, display_name, created_at, is_admin bool DEFAULT false)
identities   (user_id FK, issuer text, subject text, PRIMARY KEY (issuer, subject))   -- account linking + issuer portability
invites      (code text PK, created_by FK users, max_uses int, used_count int, expires_at, created_at)
feeds        (id uuid PK, slug text UNIQUE, name, description, created_by FK users, created_at, is_active bool)
feed_topics  (feed_id FK, topic text, added_by FK users, created_at, PRIMARY KEY (feed_id, topic))
feed_sources (feed_id FK, url text, kind text, added_by FK users, created_at, is_active bool, PRIMARY KEY (feed_id, url))
memberships  (user_id FK, feed_id FK, role text DEFAULT 'member', notify_email bool, notify_push bool, joined_at, PRIMARY KEY (user_id, feed_id))
briefs       (feed_id FK, date date, format text, payload jsonb, article_url, article_title, model, eval_score real, created_at, PRIMARY KEY (feed_id, date))
feedback     (user_id FK, feed_id, date, aspect text, value smallint, created_at, PRIMARY KEY (user_id, feed_id, date, aspect))
device_tokens(user_id FK, platform text, token text UNIQUE, app_version, is_active bool, updated_at)
notifications_sent (feed_id, date, user_id, channel text, sent_at, PRIMARY KEY (feed_id, date, user_id, channel))
runs         (date date, feed_id, status text, article_url, input_tokens, output_tokens, est_cost_usd, error text, PRIMARY KEY (date, feed_id))
```

Decisions: briefs store the V3 JSON verbatim (`payload`) and upsert on `(feed_id, date)` — today's date-keyed replay semantics survive; feedback becomes a relational upsert (fixes the read-modify-write race) and enables per-feed calibration; `identities` makes one human ↔ N credentials and is the Supabase exit hatch; `device_tokens.user_id` is what per-user fan-out needs; roles are minimal (creator = owner, everyone else member; `is_admin` = Anton); `notifications_sent` makes fan-out idempotent per (brief, user, channel); `runs` is the per-feed observability record.

## 4. Auth and invites

- Clients embed the Supabase SDK (Swift / Kotlin) as an identity widget only: Apple (native sheet on iOS), Google, email magic link/OTP. Supabase's magic-link email is wired to Anton's own SMTP (free-tier built-in mail is rate-limited).
- The API verifies Supabase JWTs locally (JWKS cached, issuer/audience pinned). Supabase is never in the data path; outages don't affect signed-in sessions until token expiry.
- **Invite gate in the API, not Supabase:** a valid JWT with no `identities` row → `403 invite_required`; `POST /v1/users {invite_code}` validates the code and creates user + identity + increments `used_count` in one transaction. Codes are minted by the admin; `max_uses` supports one code per team/channel.
- **Account linking:** a second provider with a matching *verified* email attaches a new `identities` row; unverified collisions are rejected.
- **Legacy:** Firebase anonymous UIDs are not migrated; legacy `feedback/{date}.json` stays readable for the `engineering` feed until decommission; Firebase Auth is removed from Swift in Phase 3.
- **Pipeline auth:** static 256-bit service token (Secret Manager on the GCP side) on `/internal/*` only.
- **Exit path:** later self-host Supabase's auth component (GoTrue) on the box; relink users by verified email; config change + migration script, not a re-architecture.

## 5. Multi-feed pipeline (daily-agent)

Unit of work becomes a feed. `GET /internal/feeds` (active feeds with sources + topics) replaces `config/sources.json`; if the API is unreachable at start, the job runs the legacy single-feed path and alerts.

Per run: fetch the union of all feeds' sources once (per-URL cache) → for each feed, bounded parallelism (3), per-feed error isolation → candidates = that feed's sources, last 24h → two-phase selection with **topics injected as the feed's interests** (Phase-1 headline shortlist on Haiku; Opus final pick) → **cross-feed dedup** by article URL (shared scrape/brief/judge) → V3 brief (Opus) + shadow lane unchanged → judge (Gemini, scores + pairwise winner) → `POST /internal/briefs` upsert → `POST /internal/runs` with per-feed status/tokens/cost.

Guarantees: a feed with no new articles makes zero LLM calls; one feed failing never aborts others; `(feed_id, date)` upsert keeps re-runs safe; `--date` backfill gains `--feed <slug>`; the `engineering` feed keeps dual-writing GCS + manifest until Phase 6. Cost tracks *distinct selected articles per day*, not feed count.

## 6. API and notifications (`pulse-api`, Rust/axum)

Route groups and auth: `/v1/*` Bearer Supabase JWT → `user_id` (apps); `/internal/*` service token (pipeline); `/admin/*` JWT + `is_admin`.

`/v1`: `POST /users {invite_code}`; `GET /me`; `GET|POST /feeds`; `POST|DELETE /feeds/{id}/membership` (+ notify prefs); `POST|DELETE /feeds/{id}/topics` and `/sources` (source URL is fetched and validated as RSS/Atom before accept, no LLM in the request path); `GET /feeds/{id}/briefs?before=` (paginated; replaces manifest.json); `GET /briefs/{feed}/{date}`; `PUT /briefs/{feed}/{date}/feedback`; `PUT|DELETE /devices`.
`/internal`: `GET /feeds`, `POST /briefs` (upsert; **triggers notifications**), `POST /runs`, `GET /feedback?feed=&since=` (calibration context).

Notifications fan out on brief ingest to members with notifications enabled: email (V3 HTML renderer ported from `functions/notifier`, SMTP), APNs (direct HTTP/2, ES256 JWT — as `apns_utils.py` today), FCM (HTTP v1, service-account credential in env). Idempotent per `(brief, user, channel)` via `notifications_sent`; delivery failures are logged per recipient and never fail ingest; invalid tokens deactivate the device row. There is no unauthenticated route; the public bucket can therefore be retired.

## 7. Clients

- **Shared contract:** a small versioned JSON surface; the V3 `InsightBrief` payload is byte-identical across storage backends, so brief-rendering code never changes. The shared Rust crate emits JSON fixtures that both mobile test suites decode (contract tests).
- **Swift (primary):** `APIService` targets `https://api.eng-pulse.tsvetkov.org/v1` with the Supabase JWT; `CacheService` unchanged; sign-in + invite screens (Supabase Swift SDK); Firebase Auth removed; `FeedbackService` → API; Feeds tab (browse/join/leave, per-feed detail with topics/sources/notify toggle) + feed picker on Home ("All my feeds" merged by date); TTS/CarPlay/design refresh untouched; APNs registration → `PUT /v1/devices`. Existing users are auto-joined to `engineering` on first sign-in.
- **Android (native Kotlin/Compose, new project, Phase 5):** Compose UI; Supabase Kotlin SDK (same sign-in menu; Apple via web flow); Room offline cache; **Media3 + Android `TextToSpeech`** for background playback with lock-screen controls (Android Auto later); FCM via Firebase Android SDK → `PUT /v1/devices`. Gets its own spec/plan.
- **Flutter:** archived (removed from CI; history retained).
- Migration without a flag day: the API ships and a new Swift build lands before anything old is turned off; old builds keep reading the bucket until every device has moved.

## 8. Infrastructure as code (Terraform)

```
infra/hetzner/   hcloud_server (cx22, Ubuntu 24.04, cloud-init) · hcloud_primary_ip · hcloud_volume (10 GB Postgres data)
                 hcloud_firewall (22 from Anton's IP; 80/443 public) · hcloud_ssh_key
                 dns.tf: cloudflare_record A api.eng-pulse.tsvetkov.org (+ eng-pulse.tsvetkov.org reserved), DNS-only
                 backend: GCS bucket tsvet01-terraform-state (versioned, native locking)
infra/gcp/       Phase 6: import {} blocks for cloud scheduler jobs, monitoring channel/policies, uptime check on /healthz, buckets
```

- DNS: Cloudflare (first-party provider); GoDaddy stays registrar (one-time NS switch if needed).
- Box runtime via cloud-init → docker compose: `caddy` (auto-TLS) → `pulse-api` (image from GHCR) → `postgres:16` (volume) + `backup` sidecar (nightly `pg_dump` → private GCS bucket, 30-day retention).
- **Terraform provisions; CI deploys.** GitHub Actions builds/pushes the API image and SSHes `docker compose pull && up -d`. Cloud Run jobs stay CI-deployed, outside Terraform.
- **Secrets never enter Terraform state:** `HCLOUD_TOKEN`/Cloudflare token via env; runtime secrets (JWKS URL, service token, SMTP, APNs key, FCM SA JSON) are GitHub Actions secrets written to `/opt/pulse/.env` by the deploy workflow.
- Monitoring reuses Cloud Monitoring: uptime check on `/healthz` → existing email channel; per-feed staleness later from `runs`.
- Cost: ≈ €5/month fixed.

## 9. Migration sequencing (strangler)

| Phase | Ships | Old system |
|---|---|---|
| 0 Foundations | Root Cargo workspace + `pulse-core` crate; Terraform hetzner + Cloudflare; box with Caddy/Postgres/`/healthz`; Supabase project (providers + SMTP) | untouched |
| 1 API MVP | Users/invites/identities, feeds/memberships/topics/sources, briefs ingest+read, feedback, devices; `engineering` seeded from `sources.json`; pipeline dual-writes; API fan-out **off** | old notifier notifies |
| 2 Swift on API | Sign-in + invite, reads/feedback/devices via API, Feeds tab; ship to Anton's phone; invite friends | old builds read bucket |
| 3 Notification cutover | API fan-out on; GCS notifier disabled; `feedback-receiver`/`fcm-tokens`/`apns-notifier` deleted; Firebase Auth removed from Swift | Firebase = FCM only |
| 4 Multi-feed pipeline | Section 5 in full | GCS writes only for legacy feed |
| 5 Android | Native Kotlin app (own spec/plan) | — |
| 6 Decommission | Manifest writes stop; bucket private; `infra/gcp` imports; optionally pipeline → cron on the box | GCS-as-API gone |

Rule: a real run + a real device at every phase boundary before the next starts. Each phase gets its own implementation plan.

## 10. Testing and error handling

- Unit tests per crate (TDD); API integration tests with `sqlx` against a throwaway Postgres in CI; contract fixtures consumed by Swift and Kotlin tests; `--smoke` extended to hit `/healthz` and `/internal/feeds`; quarterly backup-restore drill.
- Pipeline: per-feed isolation; legacy-path fallback if the API is down; alert via run report. API: notification failures never fail ingest; JWT verification fails closed; migrations run on startup and refuse to serve on failure. Box: nightly off-box backups; uptime check → email.

## 11. Cost model

- Today ≈ $8/month (≈ $7 LLM, pennies GCP).
- Multi-user at ~50 users / ~10 feeds: Hetzner €5 + Supabase free + GCP ≈ unchanged + LLM ≈ $15–30 → **≈ $20–35/month**. LLM is ~80% of the increase and is identical on any host.
- GCP-native comparison at the same scale: Cloud Run + Firestore ≈ $0–2 hosting (rejected: proprietary), Cloud Run + Cloud SQL ≈ $10–12, Cloud Run + Supabase free ≈ $1–2. Hetzner is ~$4–5/month more than the cheapest variants at 50 users but flat with growth, owned, and portable.
- Levers: Haiku headline shortlist (built in); **retire the legacy V1 dual-provider path after Opus 5 promotion** (roughly half of today's LLM calls produce nothing users see); cap active feeds.

## 12. Roadmap items outside this spec

Opus 5 promotion decision (shadow lane running); V1 retirement; Android Auto; watch app; explorer proposing sources to feed owners; account-linking UI; per-feed staleness alerts from `runs`.
