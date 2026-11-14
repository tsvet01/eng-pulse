# Notification Outbox and Sender Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pilot accounts receive one email and one push per new daily brief, according to their own preferences, from `pulse-api`.

**Architecture:** Storing today's brief enqueues one `notification_outbox` row per `(feed, date, user, channel)` in the same transaction. A worker task inside `pulse-api` leases due rows, rechecks the account, sends through SMTP or APNs, and records the outcome with bounded retries. Both channels stay off until their flag is set.

**Tech Stack:** Rust, axum 0.8, sqlx 0.9 / Postgres 18, `lettre` (SMTP), `reqwest` with `http2` (APNs), `jsonwebtoken` ES256.

**Spec:** `docs/superpowers/specs/2026-09-01-multiuser-cohorts-design.md` §6 (lines 72, 108–112) and step 5 of `docs/superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md`.

## Global Constraints

- Outbox key is unique on `(feed_id, date, user_id, channel)`; channels are `email` and `push`.
- Brief storage never fails or waits because SMTP or APNs is unavailable.
- Historic imports create no notifications. Only a brief dated today (UTC) enqueues; reconciliation may enqueue a missed current-day brief through the same key.
- Before every send, recheck: user active, membership present, channel preference on, and for push the token is active and owned by that user.
- Delivery is at least once. `notifications_sent` records provider acceptance, not receipt.
- Invalid APNs tokens are deactivated.
- GCP jobs, the legacy `functions/notifier` and `functions/apns-notifier`, and old clients are not changed.
- No credentials in the repository. Secrets arrive only through `PULSE_ENV`; values must match `SAFE_VALUE` in `scripts/prepare_api_env.py`, so the APNs key is stored base64-encoded.
- Comments and docs stay compact.

## Decisions

- **Worker placement:** a tokio task in the API process, started like `reconciliation::run`. No new container.
- **Retries:** at most 5 attempts; delay after attempt n is 1, 5, 15, 60 minutes. A lease lasts 2 minutes. A row older than 12 hours is not sent.
- **States:** `pending`, `sent`, `failed` (attempts exhausted or permanent error), `skipped` (recheck said no, or expired).
- **Push fan-out:** one `push` row per user; the worker sends to every active iOS token of that user. The row is `sent` when at least one token accepts.
- **Flags:** `NOTIFY_EMAIL_ENABLED` and `NOTIFY_PUSH_ENABLED`, both default `false`. A disabled channel enqueues nothing, so enabling it later cannot release a backlog.
- **Legacy overlap:** the pilot bundle `org.tsvetkov.eng-pulse` has its own APNs tokens, so push cannot double-send. Legacy email goes to the single `DEST_EMAIL`; if that address is also a pilot account it gets both emails until one side is turned off (Task 6 runbook).
- **Out of scope:** the iOS client (token registration with `/v1/devices`, preference toggles) is a separate plan that consumes Task 4 and Task 5's routes. FCM/Android is deferred.

## Review Focus

- A brief re-posted for today (backfill replaces the row): readers must not be notified twice. Task 1.
- The API restarts mid-send: the leased row must be picked up again after the lease expires, not lost. Task 2.
- A user turns off email while their row is pending: no email is sent. Task 2.
- A user has push on but no registered device: the row ends `skipped`, not retried five times and alerted. Task 2.
- SMTP is down for an hour at 06:00 UTC: the brief is stored, readable, and the email arrives after recovery. Tasks 1–2.

## File and responsibility map

| File | Responsibility |
|---|---|
| `apps/pulse-api/migrations/0008_notification_outbox.sql` | Outbox table, `device_tokens.environment` |
| `apps/pulse-api/src/db/outbox.rs` | Enqueue, lease, recheck, record outcome, backlog probe |
| `apps/pulse-api/src/notify/mod.rs` | `Deliver` trait, `SendError`, `Message`, worker loop |
| `apps/pulse-api/src/notify/message.rs` | Email and push text from a stored brief |
| `apps/pulse-api/src/notify/smtp.rs` | SMTP delivery |
| `apps/pulse-api/src/notify/apns.rs` | APNs delivery |
| `apps/pulse-api/tests/outbox.rs`, `tests/notify_worker.rs`, `tests/notify_apns.rs` | Tests |

---

### Task 1: Outbox table and enqueue on publication

**Files:**
- Create: `apps/pulse-api/migrations/0008_notification_outbox.sql`, `apps/pulse-api/src/db/outbox.rs`, `apps/pulse-api/tests/outbox.rs`
- Modify: `apps/pulse-api/src/db/mod.rs`, `src/db/briefs.rs` (`upsert`), `src/routes/internal.rs` (`ingest_brief`), `src/history.rs` (`import_inner`), `src/config.rs`, `tests/common/mod.rs`, `tests/schema.rs`

**Interfaces:**
- Produces:
  - `pub struct Channels { pub email: bool, pub push: bool }` in `db/outbox.rs`; `Config` gains `pub notify: Channels` parsed from `NOTIFY_EMAIL_ENABLED` / `NOTIFY_PUSH_ENABLED` (absent or `false` → off, `true` → on, anything else is an error like `RECONCILE_HISTORY_ENABLED`).
  - `pub async fn enqueue(tx: &mut Transaction<'_, Postgres>, feed_id: Uuid, date: NaiveDate, today: NaiveDate, channels: Channels) -> sqlx::Result<u64>` — returns rows inserted; inserts nothing unless `date == today`.
  - `briefs::upsert` takes `&mut Transaction` instead of `&PgPool` (same return value).

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

- [ ] **Step 2: Write failing tests in `tests/outbox.rs`** (`#[sqlx::test]`, helpers from `tests/common/mod.rs`; add `test_config_with(jwks_url, extra: &[(&str,&str)])` there)

  - `ingest_today_enqueues_one_row_per_member_and_channel`: two members, one with `notify_email=false`; POST `/internal/briefs` dated today with both flags on → rows are exactly `{(A,email),(A,push),(B,push)}`, all `pending`.
  - `repost_of_today_does_not_enqueue_or_reset`: mark A's email row `sent`, POST the same date again → row count unchanged, A's email row still `sent`.
  - `disabled_channel_enqueues_nothing`: flags off → zero rows, response still 200 with `created: true`.
  - `inactive_user_gets_no_row`: `users.is_active=false` → no rows for that user.
  - `past_date_ingest_is_silent`: brief dated yesterday → zero rows.
  - `history_import_enqueues_only_today`: `import_window` with an archive holding yesterday and today, today missing from `briefs` → rows only for today; run again → no new rows.

- [ ] **Step 3: Run `cargo test -p pulse-api --test outbox`** — expect compile failures for `outbox` and `notify` config.

- [ ] **Step 4: Implement**

  `enqueue` is one statement: `insert into notification_outbox (feed_id,date,user_id,channel) select m.feed_id,$2,m.user_id,c.channel from memberships m join users u on u.id=m.user_id and u.is_active cross join (values ('email'),('push')) c(channel) where m.feed_id=$1 and ((c.channel='email' and m.notify_email and $3) or (c.channel='push' and m.notify_push and $4)) on conflict do nothing`.

  `ingest_brief` opens a transaction, calls `briefs::upsert`, then `enqueue` when `created`, then commits. `import_inner` calls `enqueue` inside its existing transaction for each brief whose insert affected one row; it takes `Channels` as a new parameter (pass through `import_window`, `reconcile_cycle`, `reconciliation::run`; the `import-history` CLI passes both off).

- [ ] **Step 5: Run `cargo test -p pulse-api`** — expect all green, including the updated `tests/schema.rs` table list.

- [ ] **Step 6: Commit** — `feat(api): enqueue notifications with today's brief`

### Task 2: Worker — lease, recheck, record

**Files:**
- Create: `apps/pulse-api/src/notify/mod.rs`, `apps/pulse-api/tests/notify_worker.rs`
- Modify: `apps/pulse-api/src/db/outbox.rs`, `src/lib.rs` (module only)

**Interfaces:**
- Consumes: `outbox::enqueue`, table from Task 1.
- Produces, in `notify/mod.rs`:

```rust
pub struct Message { pub title: String, pub body: String, pub html: String, pub article_url: String, pub feed_slug: String, pub date: NaiveDate }
pub enum SendError { Transient(String), Permanent(String), InvalidToken }
pub trait Deliver: Send + Sync {
    fn email(&self, to: &str, m: &Message) -> impl Future<Output = Result<(), SendError>> + Send;
    fn push(&self, token: &str, sandbox: bool, m: &Message) -> impl Future<Output = Result<(), SendError>> + Send;
}
pub const MAX_ATTEMPTS: i32 = 5;
pub fn backoff(attempts: i32) -> chrono::Duration; // 1 → 1 min, 2 → 5, 3 → 15, 4+ → 60
pub async fn run_once(pool: &PgPool, d: &impl Deliver, now: DateTime<Utc>) -> Result<usize, String>; // rows processed
pub async fn run(pool: PgPool, d: impl Deliver) -> Result<(), String>; // 30 s ticks, never returns Ok
```

- Produces, in `db/outbox.rs`: `lease(pool, now, limit: i64) -> Vec<Leased>`, `recipient(pool, &Leased) -> Option<Recipient>` (`Recipient { email: String, tokens: Vec<(String, bool)> }`, `None` when the recheck fails), `mark_sent`, `mark_skipped(reason)`, `mark_retry(error, now)`, `mark_failed(error)`. `Message` is built by a private `fn message(row: &BriefRow, slug: &str) -> Message` placeholder here and replaced in Task 3.

- [ ] **Step 1: Write failing tests in `tests/notify_worker.rs`** using a `Fake` deliverer that records calls and returns scripted results. Each test enqueues via Task 1 and calls `run_once` with an explicit `now`.

  - `sends_email_and_push_and_records_acceptance`: both rows `sent`; `notifications_sent` has both; fake saw one email to the user's address and one push per active token.
  - `opt_out_while_pending_is_skipped`: set `notify_email=false` after enqueue → no email call, row `skipped`, `last_error = 'preference_off'`.
  - `deactivated_user_and_removed_membership_are_skipped`: reasons `user_inactive`, `not_member`.
  - `push_without_device_is_skipped`: reason `no_device`; no retry scheduled.
  - `transient_failure_retries_with_backoff`: fake returns `Transient` → row `pending`, `attempts = 1`, `next_attempt_at = now + 1 min`, `lease_expires_at` null; `run_once(now)` again processes nothing; `run_once(now + 1 min)` sends.
  - `exhausted_attempts_fail`: five `Transient` results across advancing clocks → `failed`, `attempts = 5`, `last_error` kept.
  - `permanent_failure_fails_once`: `Permanent` → `failed` with `attempts = 1`.
  - `invalid_token_is_deactivated`: two tokens, one returns `InvalidToken` → that `device_tokens.is_active = false`, row `sent`. With one token only → row `skipped`, reason `no_device`.
  - `expired_lease_is_released`: lease a row and do nothing; `run_once(now + 3 min)` sends it.
  - `concurrent_workers_send_once`: two `run_once` futures joined on the same `now` → fake saw exactly one email.
  - `stale_row_is_not_sent`: `created_at = now − 13 h` → `skipped`, reason `expired`.
  - `token_moved_to_another_user_is_not_used`: token reassigned after enqueue → not sent to; reason `no_device`.

- [ ] **Step 2: Run `cargo test -p pulse-api --test notify_worker`** — expect compile failure.

- [ ] **Step 3: Implement**

  Lease: `update notification_outbox set lease_expires_at=$1 + interval '2 minutes', attempts=attempts+1, updated_at=$1 where (feed_id,date,user_id,channel) in (select feed_id,date,user_id,channel from notification_outbox where state='pending' and next_attempt_at<=$1 and (lease_expires_at is null or lease_expires_at<$1) order by next_attempt_at limit $2 for update skip locked) returning feed_id,date,user_id,channel,attempts,created_at`. Every `mark_*` clears the lease. `mark_sent` also inserts into `notifications_sent` with `on conflict do nothing`, in one transaction. A provider call is bounded by a 20-second timeout that counts as `Transient`. `last_error` holds a short reason, never a token or address.

- [ ] **Step 4: Run `cargo test -p pulse-api`** — green.

- [ ] **Step 5: Commit** — `feat(api): add notification worker with leases and retries`

### Task 3: Message text and SMTP delivery

**Files:**
- Create: `apps/pulse-api/src/notify/message.rs`, `apps/pulse-api/src/notify/smtp.rs`
- Modify: `apps/pulse-api/Cargo.toml` (`lettre = { version = "0.11", default-features = false, features = ["builder", "smtp-transport", "tokio1-rustls-tls"] }`), `src/notify/mod.rs`

**Interfaces:**
- Produces: `pub fn build(row: &BriefRow, feed_slug: &str) -> Message` in `message.rs`; `pub struct SmtpConfig { host, port: u16, user, password, from }`; `pub struct Smtp` with `pub fn new(cfg: &SmtpConfig) -> Result<Self, String>` and `pub async fn send(&self, to: &str, m: &Message) -> Result<(), SendError>`.

- [ ] **Step 1: Write failing unit tests in `message.rs`**

  - `title_is_article_title`; `body_is_key_idea_cut_to_178_chars_on_a_word`; missing `key_idea` → body is the article title.
  - `html_escapes_payload_text`: payload containing `<script>` appears escaped; `html` contains `key_idea`, `why_it_matters`, `what_to_change` when non-null, and the article link.
  - `html_ends_with_opt_out_line`: contains `Turn off email in the app under Settings.`

- [ ] **Step 2: Write failing unit tests in `smtp.rs`** for a private `fn classify(code: u16) -> SendError`: 4xx → `Transient`, 5xx → `Permanent`; connection or TLS error → `Transient`.

- [ ] **Step 3: Run `cargo test -p pulse-api notify::`** — fail.

- [ ] **Step 4: Implement.** Email subject is `Eng Pulse: {title}`; multipart with plain text and HTML; STARTTLS on the configured port. Replace Task 2's placeholder `message` with `message::build`.

- [ ] **Step 5: Run `cargo test -p pulse-api` and `cargo clippy -p pulse-api --all-targets -- -D warnings`** — green.

- [ ] **Step 6: Commit** — `feat(api): render and send brief emails over SMTP`

### Task 4: APNs delivery and device environment

**Files:**
- Create: `apps/pulse-api/src/notify/apns.rs`, `apps/pulse-api/tests/notify_apns.rs`
- Modify: `apps/pulse-api/Cargo.toml` (add `http2` to `reqwest` features), `src/db/devices.rs`, `src/routes/devices.rs`, `tests/devices.rs`

**Interfaces:**
- Produces: `pub struct ApnsConfig { key_pem: String, key_id: String, team_id: String, topic: String, production_url: String, sandbox_url: String }`; `pub struct Apns` with `new(cfg) -> Result<Self, String>` and `send(&self, token: &str, sandbox: bool, m: &Message) -> Result<(), SendError>`. `PUT /v1/devices` accepts optional `"environment": "sandbox" | "production"` (default `production`); `devices::upsert` gains `environment: &str`.

- [ ] **Step 1: Write failing tests in `tests/notify_apns.rs`** against a `wiremock` server used as both URLs, with the throwaway P-256 key from `tests/common/mod.rs`.

  - `posts_alert_with_required_headers`: path `/3/device/{token}`; headers `apns-topic: org.tsvetkov.eng-pulse`, `apns-push-type: alert`, `authorization: bearer <jwt>` where the JWT has `alg ES256`, `kid`, `iss = team_id`; body `{"aps":{"alert":{"title":…,"body":…},"sound":"default"},"feed":"engineering","date":"YYYY-MM-DD"}`.
  - `sandbox_flag_selects_sandbox_url`.
  - `status_mapping`: 200 → `Ok`; 410 → `InvalidToken`; 400 with reason `BadDeviceToken` or `DeviceTokenNotForTopic` → `InvalidToken`; 400 other → `Permanent`; 403 → `Permanent`; 429, 500, 503 → `Transient`.
  - `jwt_is_reused_within_50_minutes`: two sends carry the same token.

- [ ] **Step 2: Add to `tests/devices.rs`**: `environment` stored; invalid value → 400; omitted → `production`.

- [ ] **Step 3: Run both test files** — fail.

- [ ] **Step 4: Implement.** One `reqwest::Client` with `http2_prior_knowledge` off (ALPN negotiates h2; wiremock speaks HTTP/1.1) and a 10-second timeout; JWT cached behind a `tokio::sync::Mutex` with its issue time.

- [ ] **Step 5: Run `cargo test -p pulse-api`** — green.

- [ ] **Step 6: Commit** — `feat(api): deliver pushes through APNs`

### Task 5: Preference read and update

**Files:**
- Modify: `apps/pulse-api/src/routes/feeds.rs`, `src/db/feeds.rs`, `tests/feeds.rs`

**Interfaces:**
- Produces: `GET /v1/feeds/{id}/membership` → `{"notify_email": bool, "notify_push": bool}`; `PATCH /v1/feeds/{id}/membership` with either or both fields → 204. Both return 404 `membership` for a non-member and never create a membership. `feeds::notify_prefs(pool, user, feed) -> Option<(bool, bool)>`, `feeds::update_notify_prefs(pool, user, feed, Option<bool>, Option<bool>) -> bool`.

- [ ] **Step 1: Write failing tests in `tests/feeds.rs`**: defaults read as `true/true`; PATCH one field leaves the other; PATCH by a non-member → 404 and no membership row afterwards; empty PATCH body → 400; user A's PATCH does not change user B.
- [ ] **Step 2: Run `cargo test -p pulse-api --test feeds`** — fail.
- [ ] **Step 3: Implement** with `update memberships … where user_id=$1 and feed_id=$2`.
- [ ] **Step 4: Run `cargo test -p pulse-api`** — green.
- [ ] **Step 5: Commit** — `feat(api): read and update notification preferences`

### Task 6: Wiring, health, configuration and runbook

**Files:**
- Create: `docs/runbooks/notifications.md`, `scripts/check-pilot-notifications.sh`
- Modify: `apps/pulse-api/src/config.rs`, `src/lib.rs`, `src/routes/mod.rs`, `src/notify/mod.rs`, `apps/pulse-api/.env.example`, `scripts/prepare_api_env.py`, `scripts/tests/test_prepare_api_env.py`, `config/pilot-auth.json`, `.github/workflows/pilot-freshness.yml`, `docs/superpowers/plans/2026-10-13-hetzner-multiuser-pilot.md`

**Interfaces:**
- Consumes: `Smtp`, `Apns`, `run`, `Channels`.
- Produces: `GET /healthz/notifications` → 200 `{"status":"ok","reason":"current"}` or 503 `{"status":"degraded","reason": "disabled" | "failed" | "backlog" | "unavailable"}`.

- [ ] **Step 1: Write failing config tests in `config.rs`**

  - Flags off → no SMTP/APNs variables needed.
  - `NOTIFY_EMAIL_ENABLED=true` requires `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`; the error names the first missing one.
  - `NOTIFY_PUSH_ENABLED=true` requires `APNS_KEY_BASE64`, `APNS_KEY_ID`, `APNS_TEAM_ID`; `APNS_TOPIC` defaults to `org.tsvetkov.eng-pulse`; a value that is not base64 of a PEM key is an error.

- [ ] **Step 2: Write failing health tests in `tests/notify_worker.rs`**: both flags off → `disabled`; a `failed` row updated in the last 24 h → `failed`; a `pending` row with `created_at` older than 30 min → `backlog`; otherwise `ok`.

- [ ] **Step 3: Write failing cases in `scripts/tests/test_prepare_api_env.py`**: the two flags are required public keys with `true`/`false` values; a flag set `true` without its private keys in `PULSE_ENV` is rejected; private notification keys pass through when present.

- [ ] **Step 4: Run the three test sets** — fail.

- [ ] **Step 5: Implement.** A private `struct Senders { smtp: Option<Smtp>, apns: Option<Apns> }` implements `Deliver`; a call on a missing sender returns `Permanent("channel_disabled")`. In `lib.rs`, when either flag is on, add the worker as a third `tokio::select!` branch beside reconciliation; a stopped worker ends the process as reconciliation does. `config/pilot-auth.json` sets both flags `false`.

- [ ] **Step 6: Add `scripts/check-pilot-notifications.sh`** (same shape as `scripts/check-pilot-freshness.sh`, default URL `https://api.eng-pulse.tsvetkov.org/healthz/notifications`, treats `disabled` as success) and a step for it in `pilot-freshness.yml`.

- [ ] **Step 7: Write `docs/runbooks/notifications.md`**: secrets to add to `PULSE_ENV` (names only), how to base64 the `.p8` key, enable order (email first, then push), how to read backlog and failures with one SQL query each, how to turn a channel off, and that turning off does not replay old rows. Include the legacy overlap note from Decisions and the at-least-once statement.

- [ ] **Step 8: Run `cargo test -p pulse-api`, `cargo clippy --workspace --all-targets -- -D warnings`, `cargo fmt --check`, `python3 -m pytest scripts/tests`** — green.

- [ ] **Step 9: Update step 5 of the pilot plan** with what shipped and what evidence remains, then commit — `feat(api): run the notification worker behind per-channel flags`

---

## Release and evidence (after merge, needs Anton)

1. Add SMTP and APNs secrets to `PULSE_ENV`; approve `deploy-api` with both flags still `false`. Confirm `/healthz/notifications` reports `disabled`.
2. Set `NOTIFY_EMAIL_ENABLED=true` in `config/pilot-auth.json`, deploy, and confirm real email receipt for two accounts on the next 06:00 UTC brief. Turn one account's email off and confirm it gets none the day after.
3. After the iOS plan ships token registration: set `NOTIFY_PUSH_ENABLED=true`, confirm real push receipt on two devices, sign out on one and confirm it stops.
4. Confirm the legacy `DEST_EMAIL` recipient still gets its email. Rollback is setting the flag back to `false` and deploying.
