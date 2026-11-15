mod common;
use base64::Engine;
use chrono::{DateTime, Duration, SubsecRound, Utc};
use common::*;
use pulse_api::db::outbox;
use pulse_api::notify::{run_once, Deliver, Message, SendError, MAX_ATTEMPTS};
use sqlx::PgPool;
use std::{collections::HashMap, sync::Mutex};
use uuid::Uuid;

#[derive(Default)]
struct Fake {
    calls: Mutex<Vec<(String, bool, String)>>,
    script: Mutex<HashMap<String, Vec<Result<(), SendError>>>>,
}
impl Fake {
    fn script(&self, token: &str, results: Vec<Result<(), SendError>>) {
        self.script.lock().unwrap().insert(token.into(), results);
    }
    fn calls(&self) -> Vec<(String, bool, String)> {
        self.calls.lock().unwrap().clone()
    }
}
impl Deliver for Fake {
    fn push(
        &self,
        token: &str,
        sandbox: bool,
        m: &Message,
    ) -> impl std::future::Future<Output = Result<(), SendError>> + Send {
        self.calls
            .lock()
            .unwrap()
            .push((token.into(), sandbox, m.title.clone()));
        let mut s = self.script.lock().unwrap();
        let r = match s.get_mut(token) {
            Some(v) if !v.is_empty() => v.remove(0),
            _ => Ok(()),
        };
        async move { r }
    }
}

struct Setup {
    user: Uuid,
    now: DateTime<Utc>,
}

async fn setup(pool: &PgPool, tokens: &[&str]) -> Setup {
    let feed = engineering_feed(pool).await;
    let (user, _) = registered_user(pool, "a@example.com", false).await;
    sqlx::query("insert into memberships(user_id,feed_id,notify_push) values($1,$2,true)")
        .bind(user)
        .bind(feed)
        .execute(pool)
        .await
        .unwrap();
    for t in tokens {
        sqlx::query("insert into device_tokens(user_id,platform,token) values($1,'ios',$2)")
            .bind(user)
            .bind(*t)
            .execute(pool)
            .await
            .unwrap();
    }
    let date = Utc::now().date_naive();
    sqlx::query("insert into briefs(feed_id,date,format,payload,article_url,article_title) values($1,$2,'insight-brief-v3',$3,'https://example.com/a','Title')")
        .bind(feed).bind(date).bind(serde_json::json!({"key_idea": "idea"}))
        .execute(pool).await.unwrap();
    let mut tx = pool.begin().await.unwrap();
    outbox::enqueue(&mut tx, feed, date, date, true)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    let now = Utc::now().trunc_subsecs(6);
    Setup { user, now }
}

async fn row(pool: &PgPool, s: &Setup) -> (String, i32, Option<String>) {
    sqlx::query_as("select state, attempts, last_error from notification_outbox where user_id=$1")
        .bind(s.user)
        .fetch_one(pool)
        .await
        .unwrap()
}
async fn sent_count(pool: &PgPool) -> i64 {
    sqlx::query_scalar("select count(*) from notifications_sent where channel='push'")
        .fetch_one(pool)
        .await
        .unwrap()
}
fn transient() -> SendError {
    SendError::Transient("apns 503".into())
}

#[sqlx::test]
async fn sends_to_every_active_token_and_records_acceptance(pool: PgPool) {
    let s = setup(&pool, &["t1", "t2"]).await;
    let f = Fake::default();
    assert_eq!(run_once(&pool, &f, s.now).await.unwrap(), 1);
    assert_eq!(f.calls().len(), 2);
    assert_eq!(row(&pool, &s).await.0, "sent");
    assert_eq!(sent_count(&pool).await, 1);
}

#[sqlx::test]
async fn opt_out_while_pending_is_skipped(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    sqlx::query("update memberships set notify_push=false")
        .execute(&pool)
        .await
        .unwrap();
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    assert!(f.calls().is_empty());
    let r = row(&pool, &s).await;
    assert_eq!(
        (r.0.as_str(), r.2.as_deref()),
        ("skipped", Some("preference_off"))
    );
}

#[sqlx::test]
async fn deactivated_user_and_removed_membership_are_skipped(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    sqlx::query("update users set is_active=false")
        .execute(&pool)
        .await
        .unwrap();
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    assert_eq!(row(&pool, &s).await.2.as_deref(), Some("user_inactive"));

    let s = setup_again(&pool).await;
    sqlx::query("delete from memberships where user_id=$1")
        .bind(s.user)
        .execute(&pool)
        .await
        .unwrap();
    run_once(&pool, &f, s.now).await.unwrap();
    let r = row(&pool, &s).await;
    assert_eq!(
        (r.0.as_str(), r.2.as_deref()),
        ("skipped", Some("not_member"))
    );
    assert!(f.calls().is_empty());
}

async fn setup_again(pool: &PgPool) -> Setup {
    let feed: Uuid = sqlx::query_scalar("select id from feeds")
        .fetch_one(pool)
        .await
        .unwrap();
    let (user, _) = registered_user(pool, "b@example.com", false).await;
    sqlx::query("insert into memberships(user_id,feed_id,notify_push) values($1,$2,true)")
        .bind(user)
        .bind(feed)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("insert into device_tokens(user_id,platform,token) values($1,'ios','tb')")
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    let date = Utc::now().date_naive();
    sqlx::query("delete from notification_outbox where user_id <> $1")
        .bind(user)
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("insert into notification_outbox(feed_id,date,user_id,channel) values($1,$2,$3,'push') on conflict do nothing")
        .bind(feed).bind(date).bind(user).execute(pool).await.unwrap();
    let now = Utc::now().trunc_subsecs(6);
    Setup { user, now }
}

#[sqlx::test]
async fn no_device_is_skipped(pool: PgPool) {
    let s = setup(&pool, &[]).await;
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    let r = row(&pool, &s).await;
    assert_eq!(
        (r.0.as_str(), r.2.as_deref()),
        ("skipped", Some("no_device"))
    );
    assert_eq!(
        run_once(&pool, &f, s.now + Duration::hours(1))
            .await
            .unwrap(),
        0
    );
}

#[sqlx::test]
async fn transient_failure_retries_with_backoff(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let f = Fake::default();
    f.script("t1", vec![Err(transient())]);
    run_once(&pool, &f, s.now).await.unwrap();
    let (state, attempts, err): (String, i32, Option<String>) = row(&pool, &s).await;
    assert_eq!((state.as_str(), attempts), ("pending", 1));
    assert!(err.is_some());
    let (next, lease): (DateTime<Utc>, Option<DateTime<Utc>>) =
        sqlx::query_as("select next_attempt_at, lease_expires_at from notification_outbox")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(next, s.now + Duration::minutes(1));
    assert!(lease.is_none());
    assert_eq!(run_once(&pool, &f, s.now).await.unwrap(), 0);
    assert_eq!(
        run_once(&pool, &f, s.now + Duration::minutes(1))
            .await
            .unwrap(),
        1
    );
    assert_eq!(row(&pool, &s).await.0, "sent");
}

#[sqlx::test]
async fn exhausted_attempts_fail(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let f = Fake::default();
    f.script("t1", (0..MAX_ATTEMPTS).map(|_| Err(transient())).collect());
    for i in 0..MAX_ATTEMPTS {
        run_once(&pool, &f, s.now + Duration::hours(i as i64))
            .await
            .unwrap();
    }
    let r = row(&pool, &s).await;
    assert_eq!((r.0.as_str(), r.1), ("failed", MAX_ATTEMPTS));
    assert!(r.2.unwrap().contains("503"));
}

#[sqlx::test]
async fn permanent_failure_fails_once(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let f = Fake::default();
    f.script("t1", vec![Err(SendError::Permanent("bad payload".into()))]);
    run_once(&pool, &f, s.now).await.unwrap();
    let r = row(&pool, &s).await;
    assert_eq!((r.0.as_str(), r.1), ("failed", 1));
    assert_eq!(sent_count(&pool).await, 0);
}

#[sqlx::test]
async fn invalid_token_is_deactivated(pool: PgPool) {
    let s = setup(&pool, &["t1", "t2"]).await;
    let f = Fake::default();
    f.script("t1", vec![Err(SendError::InvalidToken)]);
    run_once(&pool, &f, s.now).await.unwrap();
    let active: bool = sqlx::query_scalar("select is_active from device_tokens where token='t1'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert!(!active);
    assert_eq!(row(&pool, &s).await.0, "sent");
}

#[sqlx::test]
async fn only_invalid_token_leaves_no_device(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let f = Fake::default();
    f.script("t1", vec![Err(SendError::InvalidToken)]);
    run_once(&pool, &f, s.now).await.unwrap();
    let r = row(&pool, &s).await;
    assert_eq!(
        (r.0.as_str(), r.2.as_deref()),
        ("skipped", Some("no_device"))
    );
}

#[sqlx::test]
async fn mixed_results_count_as_sent(pool: PgPool) {
    let s = setup(&pool, &["t1", "t2"]).await;
    let f = Fake::default();
    f.script("t2", vec![Err(transient())]);
    run_once(&pool, &f, s.now).await.unwrap();
    assert_eq!(row(&pool, &s).await.0, "sent");
    assert_eq!(f.calls().len(), 2);
    assert_eq!(
        run_once(&pool, &f, s.now + Duration::hours(1))
            .await
            .unwrap(),
        0
    );
    assert_eq!(f.calls().len(), 2);
}

#[sqlx::test]
async fn expired_lease_is_released(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let l = outbox::lease(&pool, s.now, 20).await.unwrap();
    assert_eq!(l.len(), 1);
    let f = Fake::default();
    assert_eq!(
        run_once(&pool, &f, s.now + Duration::minutes(1))
            .await
            .unwrap(),
        0
    );
    assert_eq!(
        run_once(&pool, &f, s.now + Duration::minutes(3))
            .await
            .unwrap(),
        1
    );
    assert_eq!(f.calls().len(), 1);
    assert_eq!(row(&pool, &s).await.0, "sent");
}

#[sqlx::test]
async fn concurrent_workers_send_once(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let f = Fake::default();
    let (a, b) = tokio::join!(run_once(&pool, &f, s.now), run_once(&pool, &f, s.now));
    assert_eq!(a.unwrap() + b.unwrap(), 1);
    assert_eq!(f.calls().len(), 1);
}

#[sqlx::test]
async fn stale_row_is_not_sent(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    sqlx::query("update notification_outbox set created_at=$1")
        .bind(s.now - Duration::hours(13))
        .execute(&pool)
        .await
        .unwrap();
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    assert!(f.calls().is_empty());
    let r = row(&pool, &s).await;
    assert_eq!((r.0.as_str(), r.2.as_deref()), ("skipped", Some("expired")));
}

#[sqlx::test]
async fn token_moved_to_another_user_is_not_used(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let (b, _) = registered_user(&pool, "b@example.com", false).await;
    sqlx::query("update device_tokens set user_id=$1")
        .bind(b)
        .execute(&pool)
        .await
        .unwrap();
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    assert!(f.calls().is_empty());
    let r = row(&pool, &s).await;
    assert_eq!(
        (r.0.as_str(), r.2.as_deref()),
        ("skipped", Some("no_device"))
    );
}

#[sqlx::test]
async fn sandbox_token_is_sent_with_sandbox_flag(pool: PgPool) {
    let s = setup(&pool, &["t1", "t2"]).await;
    sqlx::query("update device_tokens set environment='sandbox' where token='t1'")
        .execute(&pool)
        .await
        .unwrap();
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    let mut c = f.calls();
    c.sort();
    assert_eq!((c[0].0.as_str(), c[0].1), ("t1", true));
    assert_eq!((c[1].0.as_str(), c[1].1), ("t2", false));
}

#[sqlx::test]
async fn retried_row_is_not_released_in_the_same_run(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let f = Fake::default();
    f.script("t1", vec![Err(transient())]);
    assert_eq!(run_once(&pool, &f, s.now).await.unwrap(), 1);
    assert_eq!(f.calls().len(), 1);
    assert_eq!(row(&pool, &s).await.1, 1);
}

async fn add_due_users(pool: &PgPool, n: usize) {
    let feed: Uuid = sqlx::query_scalar("select id from feeds")
        .fetch_one(pool)
        .await
        .unwrap();
    let date = Utc::now().date_naive();
    for i in 0..n {
        let (u, _) = registered_user(pool, &format!("u{i}@example.com"), false).await;
        sqlx::query("insert into memberships(user_id,feed_id,notify_push) values($1,$2,true)")
            .bind(u)
            .bind(feed)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("insert into device_tokens(user_id,platform,token) values($1,'ios',$2)")
            .bind(u)
            .bind(format!("tok{i}"))
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "insert into notification_outbox(feed_id,date,user_id,channel) values($1,$2,$3,'push')",
        )
        .bind(feed)
        .bind(date)
        .bind(u)
        .execute(pool)
        .await
        .unwrap();
    }
}

#[sqlx::test]
async fn run_continues_past_the_first_row(pool: PgPool) {
    let s = setup(&pool, &["t0"]).await;
    add_due_users(&pool, 2).await;
    let f = Fake::default();
    let now = s.now + Duration::seconds(1);
    assert_eq!(run_once(&pool, &f, now).await.unwrap(), 3);
    assert_eq!(f.calls().len(), 3);
    let sent: i64 =
        sqlx::query_scalar("select count(*) from notification_outbox where state='sent'")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(sent, 3);
}

#[sqlx::test]
async fn run_once_processes_at_most_20_rows(pool: PgPool) {
    let s = setup(&pool, &["t0"]).await;
    add_due_users(&pool, 20).await;
    let f = Fake::default();
    let now = s.now + Duration::seconds(1);
    assert_eq!(run_once(&pool, &f, now).await.unwrap(), 20);
    let left: Vec<(String, i32)> =
        sqlx::query_as("select state, attempts from notification_outbox where state<>'sent'")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(left, vec![("pending".to_string(), 0)]);
}

#[sqlx::test]
async fn late_outcome_from_a_superseded_lease_is_ignored(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    let old = outbox::lease(&pool, s.now, 1).await.unwrap().pop().unwrap();
    let later = s.now + Duration::minutes(3);
    let new = outbox::lease(&pool, later, 1).await.unwrap().pop().unwrap();
    assert_eq!(new.attempts, 2);
    outbox::mark_sent(&pool, &new, later).await.unwrap();
    outbox::mark_failed(&pool, &old, "late", later)
        .await
        .unwrap();
    assert_eq!(row(&pool, &s).await.0, "sent");
    assert_eq!(sent_count(&pool).await, 1);
}

#[sqlx::test]
async fn deactivated_feed_is_skipped(pool: PgPool) {
    let s = setup(&pool, &["t1"]).await;
    sqlx::query("update feeds set is_active=false")
        .execute(&pool)
        .await
        .unwrap();
    let f = Fake::default();
    run_once(&pool, &f, s.now).await.unwrap();
    assert!(f.calls().is_empty());
    let r = row(&pool, &s).await;
    assert_eq!(
        (r.0.as_str(), r.2.as_deref()),
        ("skipped", Some("feed_inactive"))
    );
}

fn health_app(pool: PgPool, on: bool) -> axum::Router {
    let key = base64::engine::general_purpose::STANDARD.encode(TEST_PRIVATE_KEY_PEM);
    let on = if on { "true" } else { "false" };
    app_with(
        pool,
        "https://unused.invalid/jwks",
        &[
            ("NOTIFY_PUSH_ENABLED", on),
            ("APNS_KEY_BASE64", &key),
            ("APNS_KEY_ID", "KEYID"),
            ("APNS_TEAM_ID", "TEAMID"),
        ],
    )
}

async fn health(app: &axum::Router) -> (u16, serde_json::Value) {
    send(
        app,
        axum::http::Method::GET,
        "/healthz/notifications",
        None,
        None,
    )
    .await
}

#[sqlx::test]
async fn health_is_degraded_when_the_flag_is_off(pool: PgPool) {
    let (code, body) = health(&health_app(pool, false)).await;
    assert_eq!(code, 503);
    assert_eq!(
        body,
        serde_json::json!({"status":"degraded","reason":"disabled"})
    );
}

#[sqlx::test]
async fn health_is_current_with_a_fresh_queue(pool: PgPool) {
    setup(&pool, &["t1"]).await;
    let (code, body) = health(&health_app(pool, true)).await;
    assert_eq!(code, 200);
    assert_eq!(body, serde_json::json!({"status":"ok","reason":"current"}));
}

#[sqlx::test]
async fn health_reports_a_recent_failure_and_ignores_an_old_one(pool: PgPool) {
    setup(&pool, &["t1"]).await;
    sqlx::query(
        "update notification_outbox set state='failed', updated_at=now()-interval '1 hour'",
    )
    .execute(&pool)
    .await
    .unwrap();
    let app = health_app(pool.clone(), true);
    let (code, body) = health(&app).await;
    assert_eq!((code, body["reason"].as_str()), (503, Some("failed")));
    sqlx::query("update notification_outbox set updated_at=now()-interval '25 hours'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(health(&app).await.0, 200);
}

#[sqlx::test]
async fn health_reports_a_backlog_only_after_thirty_minutes(pool: PgPool) {
    setup(&pool, &["t1"]).await;
    let app = health_app(pool.clone(), true);
    sqlx::query("update notification_outbox set created_at=now()-interval '29 minutes'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(health(&app).await.0, 200);
    sqlx::query("update notification_outbox set created_at=now()-interval '31 minutes'")
        .execute(&pool)
        .await
        .unwrap();
    let (code, body) = health(&app).await;
    assert_eq!((code, body["reason"].as_str()), (503, Some("backlog")));
}

#[sqlx::test]
async fn health_is_unavailable_when_the_database_fails(pool: PgPool) {
    let app = health_app(pool.clone(), true);
    pool.close().await;
    let (code, body) = health(&app).await;
    assert_eq!((code, body["reason"].as_str()), (503, Some("unavailable")));
}
