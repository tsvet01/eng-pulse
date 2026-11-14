mod common;
use chrono::{DateTime, Duration, Utc};
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
    let now = Utc::now();
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
    let now = Utc::now();
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
