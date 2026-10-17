mod common;
use axum::http::Method;
use chrono::{DateTime, NaiveDate, Utc};
use pulse_api::{
    history::PublicArchive,
    reconciliation::{self, CycleOutcome},
};
use serde_json::{json, Value};
use sqlx::PgPool;
use std::time::Duration;
use wiremock::{matchers::path, Mock, MockServer, ResponseTemplate};

fn end() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 10, 17).unwrap()
}
fn now() -> DateTime<Utc> {
    "2026-10-17T10:00:00Z".parse().unwrap()
}
fn source(server: &MockServer) -> PublicArchive {
    PublicArchive::new(format!("{}/archive/", server.uri()).parse().unwrap()).unwrap()
}
async fn feed(pool: &PgPool) -> uuid::Uuid {
    sqlx::query_scalar(
        "insert into feeds(slug,name) values('engineering','Engineering') returning id",
    )
    .fetch_one(pool)
    .await
    .unwrap()
}
async fn archive(server: &MockServer) {
    for name in ["manifest.json", "summaries/v3/2026-10-17.json"] {
        Mock::given(path(format!("/storage/v1/b/archive/o/{}",urlencoding::encode(name))))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"generation":"123", "timeCreated":if name=="manifest.json" {"2026-10-17T06:10:00Z"} else {"2026-10-17T06:09:00Z"}})))
            .mount(server).await;
    }
    Mock::given(path("/archive/manifest.json"))
        .respond_with(ResponseTemplate::new(200).insert_header("x-goog-generation","123").set_body_json(json!([{
            "date":"2026-10-17", "format":"insight-brief-v3", "url":format!("{}/archive/summaries/v3/2026-10-17.json",server.uri()),
            "title":"Published while API unavailable", "original_url":"https://example.org/article", "model":"model", "eval_score":0.9
        }]))).mount(server).await;
    Mock::given(path("/archive/summaries/v3/2026-10-17.json"))
        .respond_with(
            ResponseTemplate::new(200)
                .insert_header("x-goog-generation", "123")
                .set_body_json(
                    json!({"deep_dive":"The complete brief", "future_field":{"keep":null}}),
                ),
        )
        .mount(server)
        .await;
}
async fn cycle(pool: &PgPool, server: &MockServer) -> Result<CycleOutcome, String> {
    reconciliation::reconcile_cycle(pool, &source(server), end(), Duration::ZERO).await
}

#[sqlx::test]
async fn restores_missed_publication_and_replays_silently(pool: PgPool) {
    let id = feed(&pool).await;
    let server = MockServer::start().await;
    archive(&server).await;
    assert_eq!(
        cycle(&pool, &server).await.unwrap(),
        CycleOutcome::Succeeded
    );
    let first = reconciliation::status(&pool).await.unwrap().unwrap();
    assert_eq!(first.outcome, "ok");
    assert_eq!(first.attempts, 1);
    assert_eq!(first.report.as_ref().unwrap()["inserted"], 1);
    assert_eq!(first.latest_source_date, Some(end()));
    assert!(first.last_success_at.is_some());
    let row = pulse_api::db::briefs::get(&pool, id, end())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(row.payload["future_field"], json!({"keep":null}));
    assert_eq!(row.article_title, "Published while API unavailable");
    assert_eq!(
        cycle(&pool, &server).await.unwrap(),
        CycleOutcome::Succeeded
    );
    let replay = reconciliation::status(&pool).await.unwrap().unwrap();
    assert_eq!(replay.report.as_ref().unwrap()["inserted"], 0);
    assert_eq!(replay.report.as_ref().unwrap()["unchanged"], 1);
    let sent: i64 = sqlx::query_scalar("select count(*) from notifications_sent")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(sent, 0);
}

#[sqlx::test]
async fn retries_transient_source_failure_then_records_success(pool: PgPool) {
    feed(&pool).await;
    let server = MockServer::start().await;
    archive(&server).await;
    Mock::given(path("/storage/v1/b/archive/o/manifest.json"))
        .respond_with(ResponseTemplate::new(503))
        .up_to_n_times(2)
        .with_priority(1)
        .mount(&server)
        .await;
    assert_eq!(
        cycle(&pool, &server).await.unwrap(),
        CycleOutcome::Succeeded
    );
    let row = reconciliation::status(&pool).await.unwrap().unwrap();
    assert_eq!(row.attempts, 3);
    assert_eq!(row.consecutive_failures, 0);
    assert!(row.last_error.is_none());
}

#[sqlx::test]
async fn exhaustion_keeps_last_good_checkpoint_and_stops_at_three_attempts(pool: PgPool) {
    feed(&pool).await;
    let server = MockServer::start().await;
    archive(&server).await;
    cycle(&pool, &server).await.unwrap();
    let before = reconciliation::status(&pool).await.unwrap().unwrap();
    server.reset().await;
    assert_eq!(cycle(&pool, &server).await.unwrap(), CycleOutcome::Failed);
    let after = reconciliation::status(&pool).await.unwrap().unwrap();
    assert_eq!(after.outcome, "error");
    assert_eq!(after.attempts, 3);
    assert_eq!(after.consecutive_failures, 1);
    assert_eq!(after.last_success_at, before.last_success_at);
    assert_eq!(after.report, before.report);
    assert!(after.last_error.unwrap().contains("404"));
    assert_eq!(server.received_requests().await.unwrap().len(), 3);
}

#[sqlx::test]
async fn another_worker_owns_cycle_without_duplicate_fetches(pool: PgPool) {
    feed(&pool).await;
    let server = MockServer::start().await;
    let mut owner = pool.begin().await.unwrap();
    sqlx::query("select pg_advisory_xact_lock($1)")
        .bind(reconciliation::LOCK_ID)
        .execute(&mut *owner)
        .await
        .unwrap();
    assert_eq!(cycle(&pool, &server).await.unwrap(), CycleOutcome::Skipped);
    assert!(server.received_requests().await.unwrap().is_empty());
    assert!(reconciliation::status(&pool).await.unwrap().is_none());
    owner.rollback().await.unwrap();
    archive(&server).await;
    assert_eq!(
        cycle(&pool, &server).await.unwrap(),
        CycleOutcome::Succeeded
    );
}

#[sqlx::test]
async fn conflicting_live_record_is_preserved_and_reported(pool: PgPool) {
    let id = feed(&pool).await;
    sqlx::query("insert into briefs(feed_id,date,format,payload,article_url,article_title) values($1,$2,'insight-brief-v3',$3,'https://example.org/live','Live write')")
        .bind(id).bind(end()).bind(json!({"deep_dive":"Different live content"})).execute(&pool).await.unwrap();
    let server = MockServer::start().await;
    archive(&server).await;
    assert_eq!(cycle(&pool, &server).await.unwrap(), CycleOutcome::Failed);
    let checkpoint = reconciliation::status(&pool).await.unwrap().unwrap();
    assert!(checkpoint.last_success_at.is_none());
    assert!(checkpoint.last_error.unwrap().contains("differs"));
    assert_eq!(
        pulse_api::db::briefs::get(&pool, id, end())
            .await
            .unwrap()
            .unwrap()
            .article_title,
        "Live write"
    );
}

#[sqlx::test]
async fn freshness_checks_clock_source_database_and_worker_checkpoint(pool: PgPool) {
    feed(&pool).await;
    assert_eq!(
        reconciliation::probe(&pool, false, now())
            .await
            .unwrap()
            .reason,
        "disabled"
    );
    assert_eq!(
        reconciliation::probe(&pool, true, now())
            .await
            .unwrap()
            .reason,
        "uninitialized"
    );
    let server = MockServer::start().await;
    archive(&server).await;
    cycle(&pool, &server).await.unwrap();
    sqlx::query("update reconciliation_state set last_success_at=$1")
        .bind(now())
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        reconciliation::probe(&pool, true, now())
            .await
            .unwrap()
            .status,
        "ok"
    );
    assert_eq!(
        reconciliation::probe(&pool, true, now() + chrono::Duration::minutes(46))
            .await
            .unwrap()
            .reason,
        "checkpoint_stale"
    );
    sqlx::query("update reconciliation_state set latest_source_date='2026-10-16'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        reconciliation::probe(&pool, true, now())
            .await
            .unwrap()
            .reason,
        "source_behind"
    );
    sqlx::query("update reconciliation_state set latest_source_date='2026-10-17'")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("update briefs set date='2026-10-16'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        reconciliation::probe(&pool, true, now())
            .await
            .unwrap()
            .reason,
        "mirror_behind"
    );
    let early: DateTime<Utc> = "2026-10-17T07:29:59Z".parse().unwrap();
    sqlx::query(
        "update reconciliation_state set last_success_at=$1,latest_source_date='2026-10-16'",
    )
    .bind(early)
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        reconciliation::probe(&pool, true, early)
            .await
            .unwrap()
            .status,
        "ok"
    );
    assert_eq!(
        reconciliation::probe(&pool, true, early + chrono::Duration::seconds(1))
            .await
            .unwrap()
            .reason,
        "source_behind"
    );
    sqlx::query("update feeds set is_active=false")
        .execute(&pool)
        .await
        .unwrap();
    assert_ne!(
        reconciliation::probe(&pool, true, early)
            .await
            .unwrap()
            .status,
        "ok"
    );
}

#[sqlx::test]
async fn checkpoint_details_require_service_token_and_probe_is_minimal(pool: PgPool) {
    let app = common::app(pool, "https://unused.invalid/jwks");
    for token in [None, Some("wrong")] {
        assert_eq!(
            common::send(&app, Method::GET, "/internal/reconciliation", token, None)
                .await
                .0,
            401
        );
    }
    let (code, body) = common::send(
        &app,
        Method::GET,
        "/internal/reconciliation",
        Some(common::SERVICE_TOKEN),
        None,
    )
    .await;
    assert_eq!(code, 200);
    assert_eq!(body, Value::Null);
    let (code, body) = common::send(&app, Method::GET, "/healthz/briefs", None, None).await;
    assert_eq!(code, 503);
    assert_eq!(body, json!({"status":"degraded","reason":"disabled"}));
}

#[test]
fn worker_configuration_is_explicit_and_strict() {
    let mut vars = std::collections::HashMap::from([
        ("DATABASE_URL".into(), "unused".into()),
        ("SUPABASE_JWKS_URL".into(), "https://unused.invalid".into()),
        ("SUPABASE_ISSUER".into(), "issuer".into()),
        ("PIPELINE_SERVICE_TOKEN".into(), "local-test".into()),
    ]);
    assert!(
        !pulse_api::config::Config::from_map(&vars)
            .unwrap()
            .reconcile_history_enabled
    );
    vars.insert("RECONCILE_HISTORY_ENABLED".into(), "true".into());
    assert!(
        pulse_api::config::Config::from_map(&vars)
            .unwrap()
            .reconcile_history_enabled
    );
    vars.insert("RECONCILE_HISTORY_ENABLED".into(), "false".into());
    assert!(
        !pulse_api::config::Config::from_map(&vars)
            .unwrap()
            .reconcile_history_enabled
    );
    vars.insert("RECONCILE_HISTORY_ENABLED".into(), "typo".into());
    assert!(pulse_api::config::Config::from_map(&vars).is_err());
}

#[sqlx::test]
async fn cancelled_worker_releases_ownership_and_does_not_invent_success(pool: PgPool) {
    feed(&pool).await;
    let server = MockServer::start().await;
    Mock::given(path("/storage/v1/b/archive/o/manifest.json"))
        .respond_with(ResponseTemplate::new(503).set_delay(Duration::from_secs(10)))
        .mount(&server)
        .await;
    let worker_pool = pool.clone();
    let worker_source = source(&server);
    let worker = tokio::spawn(async move {
        reconciliation::reconcile_cycle(&worker_pool, &worker_source, end(), Duration::ZERO).await
    });
    tokio::time::timeout(Duration::from_secs(3), async {
        while server.received_requests().await.unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    worker.abort();
    assert!(worker.await.unwrap_err().is_cancelled());
    let interrupted = reconciliation::status(&pool).await.unwrap().unwrap();
    assert_eq!(interrupted.outcome, "running");
    assert!(interrupted.last_success_at.is_none());
    server.reset().await;
    archive(&server).await;
    assert_eq!(
        cycle(&pool, &server).await.unwrap(),
        CycleOutcome::Succeeded
    );
}

#[sqlx::test]
async fn lost_owner_cannot_overwrite_a_successor_checkpoint(pool: PgPool) {
    feed(&pool).await;
    let entered = std::sync::Arc::new(tokio::sync::Semaphore::new(0));
    let resume = std::sync::Arc::new(tokio::sync::Semaphore::new(0));
    let entered_handler = entered.clone();
    let resume_handler = resume.clone();
    let app = axum::Router::new().fallback(move || {
        let entered = entered_handler.clone();
        let resume = resume_handler.clone();
        async move {
            entered.add_permits(1);
            resume.acquire().await.unwrap().forget();
            axum::http::StatusCode::SERVICE_UNAVAILABLE
        }
    });
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let old_pool = pool.clone();
    let old_source =
        PublicArchive::new(format!("http://{address}/archive/").parse().unwrap()).unwrap();
    let old_worker = tokio::spawn(async move {
        reconciliation::reconcile_cycle(&old_pool, &old_source, end(), Duration::ZERO).await
    });
    tokio::time::timeout(Duration::from_secs(3), entered.acquire())
        .await
        .unwrap()
        .unwrap()
        .forget();
    // Kill only this test database's lock owner, while its source request is paused.
    let killed: bool = sqlx::query_scalar("select pg_terminate_backend(pid) from pg_locks where locktype='advisory' and classid=0 and objid::bigint=$1 and database=(select oid from pg_database where datname=current_database()) and granted")
        .bind(reconciliation::LOCK_ID).fetch_one(&pool).await.unwrap();
    assert!(killed);
    let successor_source = MockServer::start().await;
    archive(&successor_source).await;
    assert_eq!(
        cycle(&pool, &successor_source).await.unwrap(),
        CycleOutcome::Succeeded
    );
    let successor = serde_json::to_value(reconciliation::status(&pool).await.unwrap()).unwrap();
    resume.add_permits(3);
    let old_result = tokio::time::timeout(Duration::from_secs(5), old_worker)
        .await
        .unwrap()
        .unwrap();
    server.abort();
    assert!(old_result.is_err());
    assert_eq!(
        serde_json::to_value(reconciliation::status(&pool).await.unwrap()).unwrap(),
        successor
    );
}

#[sqlx::test]
async fn future_dated_row_cannot_mask_a_missing_current_brief(pool: PgPool) {
    feed(&pool).await;
    let server = MockServer::start().await;
    archive(&server).await;
    cycle(&pool, &server).await.unwrap();
    sqlx::query("update reconciliation_state set last_success_at=$1")
        .bind(now())
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("update briefs set date='2026-10-18'")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        reconciliation::probe(&pool, true, now())
            .await
            .unwrap()
            .reason,
        "mirror_behind"
    );
}
