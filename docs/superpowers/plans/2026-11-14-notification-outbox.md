# Notification Outbox and Push Sender Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pilot accounts receive one push per new daily brief, according to their own preference, from `pulse-api`.

**Architecture:** Storing today's brief enqueues one `notification_outbox` row per `(feed, date, user, channel)` in the same transaction. A worker task inside `pulse-api` leases due rows, rechecks the account, sends through APNs, and records the outcome with bounded retries. Sending stays off until its flag is set.

**Tech Stack:** Rust, axum 0.8, sqlx 0.9 / Postgres 18, `reqwest` with `http2` (APNs), `jsonwebtoken` ES256.

**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md` §6 (lines 72, 108–112) and step 5 of `docs/superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md`.

## Global Constraints

- **Users are notified in the app only (Anton, 2026-11-14): push, no email.** This overrides the spec's email channel. No SMTP code or dependency is added.
- Outbox key is unique on `(feed_id, date, user_id, channel)`. Only `push` rows are created; the `email` value stays allowed in the schema and unused.
- Brief storage never fails or waits because APNs is unavailable.
- Historic imports create no notifications. Only a brief dated today (UTC) enqueues; reconciliation may enqueue a missed current-day brief through the same key.
- Before every send, recheck: user active, membership present, `notify_push` on, and the token is active and owned by that user.
- Delivery is at least once. `notifications_sent` records provider acceptance, not receipt.
- Invalid APNs tokens are deactivated.
- GCP jobs, the legacy `functions/notifier` and `functions/apns-notifier`, and old clients are not changed.
- No credentials in the repository. Secrets arrive only through `PULSE_ENV`; values must match `SAFE_VALUE` in `scripts/prepare_api_env.py`, so the APNs key is stored base64-encoded.
- Comments and docs stay compact.

## Decisions

- **Worker placement:** a tokio task in the API process, started like `reconciliation::run`. No new container.
- **Retries:** at most 5 attempts; delay after attempt n is 1, 5, 15, 60 minutes. A lease lasts 2 minutes. A row older than 12 hours is not sent.
- **States:** `pending`, `sent`, `failed` (attempts exhausted or permanent error), `skipped` (recheck said no, or expired).
- **Fan-out:** one `push` row per user; the worker sends to every active iOS token of that user. The row is `sent` when at least one token accepts.
- **Flag:** `NOTIFY_PUSH_ENABLED`, default `false`. While off, nothing is enqueued, so enabling it later cannot release a backlog.
- **Legacy overlap:** the pilot bundle `org.tsvetkov.eng-pulse` has its own APNs tokens, so the old sender cannot double-push a pilot device. The legacy email to `DEST_EMAIL` is untouched.
- **Out of scope:** the iOS client (token registration with `/v1/devices`, push toggle) is a separate plan that consumes Task 4 and Task 5's routes. FCM/Android is deferred.

## Review Focus

- A brief re-posted for today (backfill replaces the row): readers must not be notified twice. Task 1.
- The API restarts mid-send: the leased row is picked up again after the lease expires, not lost. Task 2.
- A user turns off push while their row is pending: nothing is sent. Task 2.
- A user has push on but no registered device: the row ends `skipped`, not retried five times and alerted. Task 2.
- APNs is down for an hour at 06:00 UTC: the brief is stored and readable, and the push arrives after recovery. Tasks 1–2.

## File and responsibility map

| File | Responsibility |
|---|---|
| `apps/pulse-api/migrations/0008_notification_outbox.sql` | Outbox table, `device_tokens.environment` |
| `apps/pulse-api/src/db/outbox.rs` | Enqueue, lease, recheck, record outcome, backlog probe |
| `apps/pulse-api/src/notify/mod.rs` | `Deliver` trait, `SendError`, worker loop |
| `apps/pulse-api/src/notify/message.rs` | Push title and body from a stored brief |
| `apps/pulse-api/src/notify/apns.rs` | APNs delivery |
| `apps/pulse-api/tests/outbox.rs`, `tests/notify_worker.rs`, `tests/notify_apns.rs` | Tests |

---

### Task 1: Outbox table and enqueue on publication

**Files:**
- Create: `apps/pulse-api/migrations/0008_notification_outbox.sql`, `apps/pulse-api/src/db/outbox.rs`, `apps/pulse-api/tests/outbox.rs`
- Modify: `apps/pulse-api/src/db/mod.rs`, `src/db/briefs.rs` (`upsert`), `src/routes/internal.rs` (`ingest_brief`), `src/history.rs` (`import_inner`), `src/reconciliation.rs`, `src/lib.rs`, `src/config.rs`, `tests/common/mod.rs`, `tests/schema.rs`, and existing tests that call changed signatures

**Interfaces:**
- Produces:
  - `Config` gains `pub notify_push_enabled: bool` from `NOTIFY_PUSH_ENABLED` (absent or `false` → off, `true` → on, anything else is an error, like `RECONCILE_HISTORY_ENABLED`).
  - `pub async fn enqueue(tx: &mut Transaction<'_, Postgres>, feed_id: Uuid, date: NaiveDate, today: NaiveDate, push_enabled: bool) -> sqlx::Result<u64>` in `db/outbox.rs` — returns rows inserted; inserts nothing unless `push_enabled && date == today`.
  - `briefs::upsert` takes `&mut Transaction<'_, Postgres>` instead of `&PgPool` (same return value).
  - `tests/common/mod.rs`: `pub fn app_with(pool: PgPool, jwks_url: &str, extra: &[(&str, &str)]) -> Router` (extra config entries; `app` delegates to it with none).

- [ ] **Step 1: Write the migration**

```sql
CREATE TABLE notification_outbox (
  feed_id          uuid NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
  date             date NOT NULL,
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  channel          text NOT NULL CHECK (channel IN ('email','push')),
  state            text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','sent','failed','skipped')),
  attempts         integer NOT NULL DEFAULT 0,
  next_attempt_at  timestamptz NOT NULL DEFAULT now(),
  lease_expires_at timestamptz,
  last_error       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (feed_id, date, user_id, channel)
);
CREATE INDEX notification_outbox_due ON notification_outbox (next_attempt_at) WHERE state = 'pending';
ALTER TABLE device_tokens ADD COLUMN environment text NOT NULL DEFAULT 'production'
  CHECK (environment IN ('sandbox','production'));
```

- [ ] **Step 2: Write failing tests in `tests/outbox.rs`** (`#[sqlx::test]`, helpers from `tests/common/mod.rs`)

  - `ingest_today_enqueues_one_push_row_per_opted_in_member`: members A and B, B has `notify_push=false`; POST `/internal/briefs` dated today with the flag on → exactly one row `(A, push)`, state `pending`. No `email` rows.
  - `repost_of_today_does_not_enqueue_or_reset`: mark A's row `sent`, POST the same date again → row count unchanged, row still `sent`.
  - `flag_off_enqueues_nothing`: zero rows, response still 200 with `created: true`.
  - `inactive_user_gets_no_row`: `users.is_active=false` → no row.
  - `past_date_ingest_is_silent`: brief dated yesterday → zero rows.
  - `history_import_enqueues_only_today`: `import_window` with an archive holding yesterday and today, both absent from `briefs` → rows only for today; run again → no new rows. Follow the archive-mock pattern in `tests/history.rs`.

- [ ] **Step 3: Run `cargo test -p pulse-api --test outbox`** — expect compile failures for `outbox` and `notify_push_enabled`.

- [ ] **Step 4: Implement**

  `enqueue` is one statement: `insert into notification_outbox (feed_id,date,user_id,channel) select m.feed_id,$2,m.user_id,'push' from memberships m join users u on u.id=m.user_id and u.is_active where m.feed_id=$1 and m.notify_push on conflict do nothing`.

  `ingest_brief` opens a transaction, calls `briefs::upsert`, then `enqueue` when `created`, then commits. `import_inner` calls `enqueue` inside its existing transaction for each brief whose insert affected one row; `import_window`, `reconcile_cycle` and `reconciliation::run` gain a trailing `push_enabled: bool` parameter (the `import-history` CLI passes `false`).

- [ ] **Step 5: Run `cargo test -p pulse-api`** — all green, including the updated `tests/schema.rs`.

- [ ] **Step 6: Commit** — `feat(api): enqueue push notifications with today's brief`

### Task 2: Worker — lease, recheck, record

**Files:**
- Create: `apps/pulse-api/src/notify/mod.rs`, `apps/pulse-api/src/notify/message.rs`, `apps/pulse-api/tests/notify_worker.rs`
- Modify: `apps/pulse-api/src/db/outbox.rs`, `src/lib.rs` (module declaration only)

**Interfaces:**
- Consumes: `outbox::enqueue` and the table from Task 1.
- Produces, in `notify/mod.rs`:

```rust
pub struct Message { pub title: String, pub body: String, pub feed_slug: String, pub date: NaiveDate }
#[derive(Debug)]
pub enum SendError { Transient(String), Permanent(String), InvalidToken }
pub trait Deliver: Send + Sync {
    fn push(&self, token: &str, sandbox: bool, m: &Message) -> impl Future<Output = Result<(), SendError>> + Send;
}
pub const MAX_ATTEMPTS: i32 = 5;
pub fn backoff(attempts: i32) -> chrono::Duration; // 1 → 1 min, 2 → 5, 3 → 15, 4+ → 60
pub async fn run_once(pool: &PgPool, d: &impl Deliver, now: DateTime<Utc>) -> Result<usize, String>; // rows processed
pub async fn run(pool: PgPool, d: impl Deliver) -> Result<(), String>; // 30 s ticks, never returns Ok
```

- Produces, in `notify/message.rs`: `pub fn build(row: &BriefRow, feed_slug: &str) -> Message` — title is the article title; body is `payload.key_idea` cut to at most 178 characters on a word boundary with `…`, or the article title when `key_idea` is missing.
- Produces, in `db/outbox.rs`: `Leased { feed_id, date, user_id, attempts, created_at }`; `lease(pool, now, limit: i64) -> sqlx::Result<Vec<Leased>>`; `tokens(pool, &Leased) -> sqlx::Result<Result<Vec<(String, bool)>, &'static str>>` (`Err(reason)` when the recheck fails; bool is `environment = 'sandbox'`); `mark_sent`, `mark_skipped(reason)`, `mark_retry(error, now)`, `mark_failed(error)`.

- [ ] **Step 1: Write failing unit tests in `message.rs`**: `title_is_article_title`; `body_is_key_idea_cut_to_178_chars_on_a_word`; `missing_key_idea_falls_back_to_title`; `short_key_idea_is_unchanged`.

- [ ] **Step 2: Write failing tests in `tests/notify_worker.rs`** using a `Fake` deliverer that records calls and returns scripted results per token. Each test enqueues through Task 1 and calls `run_once` with an explicit `now`.

  - `sends_to_every_active_token_and_records_acceptance`: two tokens → two push calls, row `sent`, one `notifications_sent` row with channel `push`.
  - `opt_out_while_pending_is_skipped`: `notify_push=false` after enqueue → no call, row `skipped`, `last_error = 'preference_off'`.
  - `deactivated_user_and_removed_membership_are_skipped`: reasons `user_inactive`, `not_member`.
  - `no_device_is_skipped`: reason `no_device`; no retry scheduled.
  - `transient_failure_retries_with_backoff`: `Transient` → row `pending`, `attempts = 1`, `next_attempt_at = now + 1 min`, `lease_expires_at` null; `run_once(now)` again processes nothing; `run_once(now + 1 min)` sends.
  - `exhausted_attempts_fail`: five `Transient` results across advancing clocks → `failed`, `attempts = 5`, `last_error` kept.
  - `permanent_failure_fails_once`: `Permanent` → `failed` with `attempts = 1`.
  - `invalid_token_is_deactivated`: two tokens, one returns `InvalidToken` → that `device_tokens.is_active = false`, row `sent`. With that as the only token → row `skipped`, reason `no_device`.
  - `mixed_results_count_as_sent`: one token `Ok`, one `Transient` → row `sent` (no resend to the accepted token).
  - `expired_lease_is_released`: lease a row and do nothing; `run_once(now + 3 min)` sends it.
  - `concurrent_workers_send_once`: two `run_once` futures joined on the same `now` → exactly one push call.
  - `stale_row_is_not_sent`: `created_at = now − 13 h` → `skipped`, reason `expired`.
  - `token_moved_to_another_user_is_not_used`: token row reassigned to user B after enqueue → no call for A; reason `no_device`.
  - `sandbox_token_is_sent_with_sandbox_flag`.

- [ ] **Step 3: Run `cargo test -p pulse-api --test notify_worker` and `cargo test -p pulse-api notify::`** — expect compile failure.

- [ ] **Step 4: Implement**

  Lease: `update notification_outbox set lease_expires_at=$1 + interval '2 minutes', attempts=attempts+1, updated_at=$1 where (feed_id,date,user_id,channel) in (select feed_id,date,user_id,channel from notification_outbox where state='pending' and channel='push' and next_attempt_at<=$1 and (lease_expires_at is null or lease_expires_at<$1) order by next_attempt_at limit $2 for update skip locked) returning feed_id,date,user_id,attempts,created_at`. Every `mark_*` clears the lease and sets `updated_at`. `mark_sent` also inserts into `notifications_sent` with `on conflict do nothing`, in one transaction. A provider call is bounded by a 20-second timeout that counts as `Transient`. When no token accepted: any `Transient` → retry (or `failed` at `MAX_ATTEMPTS`); else any `Permanent` → `failed`; else `skipped` `no_device`. `last_error` holds a short reason, never a token.

- [ ] **Step 5: Run `cargo test -p pulse-api`** — green.

- [ ] **Step 6: Commit** — `feat(api): add notification worker with leases and retries`

### Task 3: APNs delivery and device environment

**Files:**
- Create: `apps/pulse-api/src/notify/apns.rs`, `apps/pulse-api/tests/notify_apns.rs`
- Modify: `apps/pulse-api/Cargo.toml` (add `http2` to `reqwest` features), `src/notify/mod.rs`, `src/db/devices.rs`, `src/routes/devices.rs`, `tests/devices.rs`

**Interfaces:**
- Consumes: `Message`, `SendError`, `Deliver` from Task 2.
- Produces: `pub struct ApnsConfig { pub key_pem: String, pub key_id: String, pub team_id: String, pub topic: String, pub production_url: String, pub sandbox_url: String }`; `pub struct Apns` with `pub fn new(cfg: ApnsConfig) -> Result<Self, String>` and `impl Deliver for Apns`. `PUT /v1/devices` accepts optional `"environment": "sandbox" | "production"` (default `production`); `devices::upsert` gains a trailing `environment: &str` and updates it on conflict.

- [ ] **Step 1: Write failing tests in `tests/notify_apns.rs`** against a `wiremock` server used as both URLs, with the throwaway P-256 key `TEST_PRIVATE_KEY_PEM` from `tests/common/mod.rs`.

  - `posts_alert_with_required_headers`: path `/3/device/{token}`; headers `apns-topic: org.tsvetkov.eng-pulse`, `apns-push-type: alert`, `authorization: bearer <jwt>` where the JWT header has `alg ES256` and `kid = key_id` and the claims have `iss = team_id` and `iat`; body `{"aps":{"alert":{"title":…,"body":…},"sound":"default"},"feed":"engineering","date":"YYYY-MM-DD"}`.
  - `sandbox_flag_selects_sandbox_url` (two mock servers).
  - `status_mapping`: 200 → `Ok`; 410 → `InvalidToken`; 400 with reason `BadDeviceToken` or `DeviceTokenNotForTopic` → `InvalidToken`; 400 other → `Permanent`; 403 → `Permanent`; 429, 500, 503 → `Transient`; connection refused → `Transient`.
  - `jwt_is_reused_within_50_minutes`: two sends carry the same token.
  - `new_rejects_a_key_that_is_not_p256_pem`.

- [ ] **Step 2: Add to `tests/devices.rs`**: `environment` is stored; an invalid value → 400; omitted → `production`; re-registering the same token with a new environment updates it.

- [ ] **Step 3: Run both test files** — fail.

- [ ] **Step 4: Implement.** One `reqwest::Client` with a 10-second timeout; do not force HTTP/2 prior knowledge (ALPN selects h2 against Apple; wiremock speaks HTTP/1.1). JWT cached behind a `tokio::sync::Mutex` with its issue time.

- [ ] **Step 5: Run `cargo test -p pulse-api`** — green.

- [ ] **Step 6: Commit** — `feat(api): deliver pushes through APNs`

### Task 4: Preference read and update

**Files:**
- Modify: `apps/pulse-api/src/routes/feeds.rs`, `src/db/feeds.rs`, `tests/feeds.rs`

**Interfaces:**
- Produces: `GET /v1/feeds/{id}/membership` → `{"notify_push": bool}`; `PATCH /v1/feeds/{id}/membership` with `{"notify_push": bool}` → 204. Both return 404 `membership` for a non-member and never create a membership. `feeds::notify_push(pool, user, feed) -> sqlx::Result<Option<bool>>`, `feeds::set_notify_push(pool, user, feed, bool) -> sqlx::Result<bool>`.

- [ ] **Step 1: Write failing tests in `tests/feeds.rs`**: default reads `true`; PATCH `false` then GET reads `false`; PATCH by a non-member → 404 and no membership row afterwards; PATCH without `notify_push` → 400 or 422 (axum's body rejection); user A's PATCH does not change user B; unknown feed → 404.
- [ ] **Step 2: Run `cargo test -p pulse-api --test feeds`** — fail.
- [ ] **Step 3: Implement** with `update memberships set notify_push=$3 where user_id=$1 and feed_id=$2`.
- [ ] **Step 4: Run `cargo test -p pulse-api`** — green.
- [ ] **Step 5: Commit** — `feat(api): read and update the push preference`

### Task 5: Wiring, health, configuration and runbook

**Files:**
- Create: `docs/runbooks/notifications.md`, `scripts/check-pilot-notifications.sh`
- Modify: `apps/pulse-api/src/config.rs`, `src/lib.rs`, `src/routes/mod.rs`, `src/notify/mod.rs`, `src/db/outbox.rs`, `apps/pulse-api/.env.example`, `scripts/prepare_api_env.py`, `scripts/tests/test_prepare_api_env.py`, `config/pilot-auth.json`, `.github/workflows/pilot-freshness.yml`, `docs/superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md`

**Interfaces:**
- Consumes: `Apns`, `ApnsConfig`, `notify::run`, `Config::notify_push_enabled`.
- Produces: `Config::apns: Option<ApnsConfig>` (`Some` exactly when the flag is on); `GET /healthz/notifications` → 200 `{"status":"ok","reason":"current"}` or 503 `{"status":"degraded","reason": "disabled" | "failed" | "backlog" | "unavailable"}`; `outbox::health(pool, now) -> sqlx::Result<&'static str>`.

- [ ] **Step 1: Write failing config tests in `config.rs`**

  - Flag off → no APNs variables needed, `apns` is `None`.
  - Flag on requires `APNS_KEY_BASE64`, `APNS_KEY_ID`, `APNS_TEAM_ID`; the error names the first missing one.
  - `APNS_TOPIC` defaults to `org.tsvetkov.eng-pulse`; URLs default to `https://api.push.apple.com` and `https://api.sandbox.push.apple.com`.
  - `APNS_KEY_BASE64` that is not valid base64 of UTF-8 text → error `APNS_KEY_BASE64 is invalid`.

- [ ] **Step 2: Write failing health tests in `tests/notify_worker.rs`**: flag off → 503 `disabled`; a `failed` row updated in the last 24 h → `failed`; a `pending` row with `created_at` older than 30 min → `backlog`; otherwise 200 `ok`.

- [ ] **Step 3: Write failing cases in `scripts/tests/test_prepare_api_env.py`**: `NOTIFY_PUSH_ENABLED` is a required public key with value `true` or `false`; `true` without `APNS_KEY_BASE64`, `APNS_KEY_ID` and `APNS_TEAM_ID` in `PULSE_ENV` is rejected; those keys pass through when present.

- [ ] **Step 4: Run the three test sets** — fail.

- [ ] **Step 5: Implement.** Add `base64 = "0.22"` to `Cargo.toml`. In `lib.rs`, when the flag is on, build `Apns` and add the worker as a `tokio::select!` branch beside the server (and beside reconciliation when that is enabled); a stopped worker ends the process as reconciliation does. `config/pilot-auth.json` sets `NOTIFY_PUSH_ENABLED` to `false`.

- [ ] **Step 6: Add `scripts/check-pilot-notifications.sh`** (same shape as `scripts/check-pilot-freshness.sh`, default URL `https://api.eng-pulse.tsvetkov.org/healthz/notifications`, treats reason `disabled` as success) and a step for it in `pilot-freshness.yml`.

- [ ] **Step 7: Write `docs/runbooks/notifications.md`**: secret names to add to `PULSE_ENV`, how to base64 the `.p8` key, how to enable, one SQL query each for backlog and failures, how to turn sending off, that turning off does not replay old rows, the legacy overlap note from Decisions, and the at-least-once statement.

- [ ] **Step 8: Run `cargo test -p pulse-api`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --check`, `python3 -m pytest scripts/tests`** — green.

- [ ] **Step 9: Update step 5 of the pilot plan** with what shipped, the push-only decision, and what evidence remains, then commit — `feat(api): run the push worker behind a flag`

---

## Release and evidence (after merge, needs Anton)

1. Add the APNs key, key ID and team ID to `PULSE_ENV`; approve `deploy-api` with the flag still `false`. Confirm `/healthz/notifications` reports `disabled`.
2. Ship the iOS plan (token registration and push toggle).
3. Set `NOTIFY_PUSH_ENABLED=true` in `config/pilot-auth.json`, deploy, and confirm real push receipt on two devices for the next 06:00 UTC brief. Turn push off on one account and confirm it gets none the day after; sign out on one device and confirm it stops.
4. Confirm the legacy recipient still gets its email and old-app push. Rollback is setting the flag back to `false` and deploying.
