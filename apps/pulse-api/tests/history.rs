use chrono::NaiveDate;
use pulse_api::history::{import_window, PublicArchive};
use serde_json::{json, Value};
use sqlx::PgPool;
use uuid::Uuid;
use wiremock::{
    matchers::{method, path},
    Mock, MockServer, ResponseTemplate,
};

fn end() -> NaiveDate {
    NaiveDate::from_ymd_opt(2026, 10, 17).unwrap()
}
fn entry(server: &MockServer, date: &str) -> Value {
    json!({"date":date,"url":format!("{}/summaries/v3/{date}.json",server.uri()),
        "title":"A title", "original_url":"https://example.org/article",
        "model":"test-model", "eval_score":0.987654321, "format":"insight-brief-v3"})
}
fn payload() -> Value {
    json!({"key_idea":"An idea","deep_dive":"Full text", "what_to_change":null,
        "future_field":{"nested":[1,2.5,null,{"keep":true}]}})
}
async fn feed(pool: &PgPool) -> Uuid {
    sqlx::query_scalar(
        "insert into feeds(slug,name) values('engineering','Engineering') returning id",
    )
    .fetch_one(pool)
    .await
    .unwrap()
}
async fn manifest(server: &MockServer, rows: Value) {
    Mock::given(method("GET"))
        .and(path("/manifest.json"))
        .respond_with(ResponseTemplate::new(200).set_body_json(rows))
        .mount(server)
        .await;
}
async fn artifact(server: &MockServer, date: &str, body: Value) {
    Mock::given(method("GET"))
        .and(path(format!("/summaries/v3/{date}.json")))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(server)
        .await;
}
fn source(server: &MockServer) -> PublicArchive {
    PublicArchive::new(format!("{}/", server.uri()).parse().unwrap()).unwrap()
}
async fn count(pool: &PgPool) -> i64 {
    sqlx::query_scalar("select count(*) from briefs")
        .fetch_one(pool)
        .await
        .unwrap()
}

#[sqlx::test]
async fn import_preserves_payload_metadata_and_personal_state_on_replay(pool: PgPool) {
    let id = feed(&pool).await;
    let server = MockServer::start().await;
    manifest(
        &server,
        json!([entry(&server, "2026-10-17"), entry(&server, "2026-09-18")]),
    )
    .await;
    artifact(&server, "2026-10-17", payload()).await;
    artifact(
        &server,
        "2026-09-18",
        json!({"deep_dive":"Minimal valid brief"}),
    )
    .await;
    let first = import_window(&pool, &source(&server), end()).await.unwrap();
    assert_eq!((first.inserted, first.unchanged, first.verified), (2, 0, 2));
    assert_eq!(
        first.window_start,
        NaiveDate::from_ymd_opt(2026, 9, 18).unwrap()
    );
    assert_eq!(first.expected_dates, vec![first.window_start, end()]);
    assert_eq!(first.missing_dates.len(), 28);
    assert!(first
        .missing_dates
        .contains(&NaiveDate::from_ymd_opt(2026, 10, 10).unwrap()));
    let user: Uuid =
        sqlx::query_scalar("insert into users(email) values('reader@example.org') returning id")
            .fetch_one(&pool)
            .await
            .unwrap();
    sqlx::query("insert into memberships(user_id,feed_id,notify_email,notify_push) values($1,$2,false,false)").bind(user).bind(id).execute(&pool).await.unwrap();
    sqlx::query(
        "insert into feedback(user_id,feed_id,date,aspect,value) values($1,$2,$3,'useful',1)",
    )
    .bind(user)
    .bind(id)
    .bind(end())
    .execute(&pool)
    .await
    .unwrap();
    let replay = import_window(&pool, &source(&server), end()).await.unwrap();
    assert_eq!(
        (replay.inserted, replay.unchanged, replay.verified),
        (0, 2, 2)
    );
    assert_eq!(count(&pool).await, 2);
    let stored = pulse_api::db::briefs::get(&pool, id, end())
        .await
        .unwrap()
        .unwrap();
    assert_eq!(stored.payload, payload());
    assert_eq!(stored.eval_score, Some(0.987654321));
    assert_eq!(stored.article_url, "https://example.org/article");
    assert_eq!(stored.article_title, "A title");
    assert_eq!(stored.model.as_deref(), Some("test-model"));
    let preferences: (bool, bool) =
        sqlx::query_as("select notify_email,notify_push from memberships where user_id=$1")
            .bind(user)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(preferences, (false, false));
    let feedback: i64 = sqlx::query_scalar("select count(*) from feedback")
        .fetch_one(&pool)
        .await
        .unwrap();
    let sent: i64 = sqlx::query_scalar("select count(*) from notifications_sent")
        .fetch_one(&pool)
        .await
        .unwrap();
    let runs: i64 = sqlx::query_scalar("select count(*) from runs")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!((feedback, sent, runs), (1, 0, 0));
}

#[sqlx::test]
async fn conflicting_existing_brief_rolls_back_new_rows(pool: PgPool) {
    let id = feed(&pool).await;
    sqlx::query("insert into briefs(feed_id,date,format,payload,article_url,article_title) values($1,$2,'insight-brief-v3',$3,'https://example.org/original','Existing title')")
        .bind(id).bind(end()).bind(json!({"deep_dive":"Existing content"})).execute(&pool).await.unwrap();
    let server = MockServer::start().await;
    manifest(
        &server,
        json!([entry(&server, "2026-10-16"), entry(&server, "2026-10-17")]),
    )
    .await;
    artifact(&server, "2026-10-16", payload()).await;
    artifact(&server, "2026-10-17", payload()).await;
    let error = import_window(&pool, &source(&server), end())
        .await
        .unwrap_err();
    assert!(error.contains("differs"), "{error}");
    assert_eq!(count(&pool).await, 1);
    assert_eq!(
        pulse_api::db::briefs::get(&pool, id, end())
            .await
            .unwrap()
            .unwrap()
            .article_title,
        "Existing title"
    );
}

#[sqlx::test]
async fn missing_or_disabled_feed_stops_before_network(pool: PgPool) {
    let server = MockServer::start().await;
    assert!(import_window(&pool, &source(&server), end())
        .await
        .unwrap_err()
        .contains("engineering"));
    feed(&pool).await;
    sqlx::query("update feeds set is_active=false")
        .execute(&pool)
        .await
        .unwrap();
    assert!(import_window(&pool, &source(&server), end())
        .await
        .unwrap_err()
        .contains("engineering"));
    assert!(server.received_requests().await.unwrap().is_empty());
}

#[sqlx::test]
async fn rejects_untrusted_or_ambiguous_manifest_before_artifact_fetch(pool: PgPool) {
    feed(&pool).await;
    for kind in [
        "external",
        "query",
        "duplicate",
        "missing_article",
        "bad_article",
        "empty",
    ] {
        let server = MockServer::start().await;
        let mut row = entry(&server, "2026-10-17");
        match kind {
            "external" => row["url"] = json!("https://untrusted.invalid/brief.json"),
            "query" => {
                row["url"] = json!(format!("{}/summaries/v3/2026-10-17.json?x=1", server.uri()))
            }
            "missing_article" => row
                .as_object_mut()
                .unwrap()
                .remove("original_url")
                .map(|_| ())
                .unwrap(),
            "bad_article" => row["original_url"] = json!("javascript:alert(1)"),
            _ => (),
        }
        let rows = if kind == "duplicate" {
            json!([row.clone(), row])
        } else if kind == "empty" {
            json!([])
        } else {
            json!([row])
        };
        manifest(&server, rows).await;
        assert!(
            import_window(&pool, &source(&server), end()).await.is_err(),
            "{kind}"
        );
        assert_eq!(server.received_requests().await.unwrap().len(), 1, "{kind}");
        assert_eq!(count(&pool).await, 0);
    }
}

#[sqlx::test]
async fn missing_malformed_redirected_or_large_artifact_never_partially_imports(pool: PgPool) {
    feed(&pool).await;
    for kind in ["missing", "malformed", "redirect", "oversized"] {
        let server = MockServer::start().await;
        manifest(
            &server,
            json!([entry(&server, "2026-10-16"), entry(&server, "2026-10-17")]),
        )
        .await;
        artifact(&server, "2026-10-16", payload()).await;
        let response = match kind {
            "missing" => ResponseTemplate::new(404),
            "malformed" => ResponseTemplate::new(200).set_body_json(json!({"deep_dive":42})),
            "redirect" => ResponseTemplate::new(302)
                .insert_header("Location", format!("{}/unexpected", server.uri())),
            _ => ResponseTemplate::new(200).set_body_string("x".repeat(2 * 1024 * 1024 + 1)),
        };
        Mock::given(path("/summaries/v3/2026-10-17.json"))
            .respond_with(response)
            .mount(&server)
            .await;
        assert!(
            import_window(&pool, &source(&server), end()).await.is_err(),
            "{kind}"
        );
        assert_eq!(count(&pool).await, 0, "{kind}");
        assert_eq!(server.received_requests().await.unwrap().len(), 3, "{kind}");
        assert!(!server
            .received_requests()
            .await
            .unwrap()
            .iter()
            .any(|r| r.url.path() == "/unexpected"));
    }
}

#[sqlx::test]
async fn ignores_other_formats_and_dates_outside_the_window(pool: PgPool) {
    feed(&pool).await;
    let server = MockServer::start().await;
    let mut legacy = entry(&server, "2026-10-16");
    legacy["format"] = json!(null);
    manifest(
        &server,
        json!([
            entry(&server, "2026-09-17"),
            entry(&server, "2026-10-18"),
            legacy,
            entry(&server, "2026-10-17")
        ]),
    )
    .await;
    artifact(&server, "2026-10-17", payload()).await;
    let report = import_window(&pool, &source(&server), end()).await.unwrap();
    assert_eq!(report.expected_dates, vec![end()]);
    assert_eq!(count(&pool).await, 1);
    let requests = server.received_requests().await.unwrap();
    assert_eq!(
        requests
            .iter()
            .filter(|r| r.url.path().starts_with("/summaries/"))
            .count(),
        1
    );
}

#[sqlx::test]
async fn rejects_failed_redirected_or_oversized_manifest_without_writes(pool: PgPool) {
    feed(&pool).await;
    for kind in ["missing", "redirect", "malformed", "oversized"] {
        let server = MockServer::start().await;
        let response = match kind {
            "missing" => ResponseTemplate::new(503),
            "redirect" => ResponseTemplate::new(302)
                .insert_header("Location", format!("{}/unexpected", server.uri())),
            "malformed" => ResponseTemplate::new(200).set_body_json(json!({"not":"an array"})),
            _ => ResponseTemplate::new(200).set_body_string("x".repeat(4 * 1024 * 1024 + 1)),
        };
        Mock::given(path("/manifest.json"))
            .respond_with(response)
            .mount(&server)
            .await;
        assert!(
            import_window(&pool, &source(&server), end()).await.is_err(),
            "{kind}"
        );
        assert_eq!(count(&pool).await, 0);
        assert_eq!(server.received_requests().await.unwrap().len(), 1);
    }
}

#[sqlx::test]
async fn changing_manifest_during_download_aborts_before_writes(pool: PgPool) {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };
    let _ = feed(&pool).await;
    let server = MockServer::start().await;
    let first = entry(&server, "2026-10-17");
    let mut second = first.clone();
    second["title"] = json!("Replacement publication");
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = calls.clone();
    Mock::given(path("/manifest.json"))
        .respond_with(move |_: &wiremock::Request| {
            let row = if counter.fetch_add(1, Ordering::SeqCst) == 0 {
                first.clone()
            } else {
                second.clone()
            };
            ResponseTemplate::new(200).set_body_json(json!([row]))
        })
        .mount(&server)
        .await;
    artifact(&server, "2026-10-17", payload()).await;
    let error = import_window(&pool, &source(&server), end())
        .await
        .unwrap_err();
    assert!(error.contains("changed"), "{error}");
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(count(&pool).await, 0);
}

#[sqlx::test]
async fn cli_rejects_options_before_network_or_database_work(pool: PgPool) {
    let error = pulse_api::history::run(&pool, &["--source=https://untrusted.invalid".into()])
        .await
        .unwrap_err();
    assert!(error.contains("takes no arguments"));
    assert_eq!(count(&pool).await, 0);
}
