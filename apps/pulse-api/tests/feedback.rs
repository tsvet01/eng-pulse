mod common;
use axum::{
    body::Body,
    http::{HeaderMap, Method, Request},
    Router,
};
use common::*;
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::PgPool;
use tower::ServiceExt;

const PATH: &str = "/v1/briefs/engineering/2026-10-18/feedback";

async fn setup(pool: &PgPool) -> (uuid::Uuid, String, String) {
    let (uid, token) = registered_user(pool, "a@example.com", false).await;
    let (other, other_token) = registered_user(pool, "b@example.com", false).await;
    let feed = engineering_feed(pool).await;
    for user in [uid, other] {
        sqlx::query("insert into memberships (user_id, feed_id) values ($1,$2)")
            .bind(user)
            .bind(feed)
            .execute(pool)
            .await
            .unwrap();
    }
    sqlx::query("insert into briefs (feed_id,date,format,payload,article_url,article_title) values ($1,'2026-10-18','insight-brief-v3','{}','https://e/article','Article')")
        .bind(feed).execute(pool).await.unwrap();
    (uid, token, other_token)
}

async fn request(
    app: &Router,
    method: Method,
    path: &str,
    token: &str,
    revision: Option<&str>,
    body: Option<Value>,
) -> (u16, HeaderMap, Value) {
    let mut req = Request::builder()
        .method(method)
        .uri(path)
        .header("authorization", format!("Bearer {token}"));
    if let Some(revision) = revision {
        req = req.header("X-Expected-Revision", revision);
    }
    let req = if let Some(body) = body {
        req.header("content-type", "application/json")
            .body(Body::from(body.to_string()))
            .unwrap()
    } else {
        req.body(Body::empty()).unwrap()
    };
    let response = app.clone().oneshot(req).await.unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body = if bytes.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(&bytes).into()))
    };
    (status, headers, body)
}

async fn identity(pool: &PgPool, date: &str) -> (uuid::Uuid, uuid::Uuid) {
    sqlx::query_as("select b.article_id,b.id from legacy_brief_identity l join article_briefs b on b.id=l.brief_id join feeds f on f.id=l.feed_id where f.slug='engineering' and l.date=$1::text::date")
        .bind(date).fetch_one(pool).await.unwrap()
}

fn stable_path(article: uuid::Uuid, aspect: &str, brief: Option<uuid::Uuid>) -> String {
    let path = format!("/v2/articles/{article}/feedback/{aspect}");
    brief.map_or(path.clone(), |id| format!("{path}?brief_id={id}"))
}

#[sqlx::test]
async fn stable_feedback_shares_article_dates_and_legacy_state_but_not_accounts(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, a, b) = setup(&pool).await;
    sqlx::query("insert into briefs select feed_id,'2026-10-19',format,payload,article_url,article_title,model,eval_score,created_at from briefs")
        .execute(&pool).await.unwrap();
    let (article, _) = identity(&pool, "2026-10-18").await;
    let app = app(pool.clone(), &url);
    let path = stable_path(article, "relevance", None);
    let (status, _, empty) = request(&app, Method::GET, &path, &a, None, None).await;
    assert_eq!(status, 200);
    assert_eq!(empty, json!({"value":null,"reason":null,"revision":0}));
    let (status, h, _) = request(
        &app,
        Method::PUT,
        &path,
        &a,
        Some("0"),
        Some(json!({"value":1,"reason":"more_like_this"})),
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "1");
    for date in ["2026-10-18", "2026-10-19"] {
        let (_, _, saved) = request(
            &app,
            Method::GET,
            &PATH.replace("2026-10-18", date),
            &a,
            None,
            None,
        )
        .await;
        assert_eq!(saved["selection"], json!({"value":1,"revision":1}));
    }
    let (_, _, other) = request(&app, Method::GET, &path, &b, None, None).await;
    assert_eq!(other, empty);
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &a,
            None,
            Some(json!({"aspect":"selection","value":-1}))
        )
        .await
        .0,
        204
    );
    assert_eq!(
        request(&app, Method::GET, &path, &a, None, None).await.2,
        json!({"value":-1,"reason":null,"revision":2})
    );
    let (status, _, export) = request(
        &app,
        Method::GET,
        "/internal/feedback?feed=engineering&since=2026-10-01",
        SERVICE_TOKEN,
        None,
        None,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(export.as_array().unwrap().len(), 2);
    assert!(export
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["aspect"] == "selection"
            && r["value"] == -1
            && r.as_object().unwrap().len() == 4));
    let historic_count: i64 = sqlx::query_scalar("select count(*) from feedback")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(historic_count, 0);
}

#[sqlx::test]
async fn stable_undo_clears_reason_and_uncertain_retries_cannot_overwrite(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let (article, _) = identity(&pool, "2026-10-18").await;
    let app = app(pool, &url);
    let path = stable_path(article, "depth", None);
    assert_eq!(
        request(
            &app,
            Method::PUT,
            &path,
            &token,
            Some("8"),
            Some(json!({"value":-1}))
        )
        .await
        .0,
        409
    );
    let body = Some(json!({"value":-1,"reason":"too_basic"}));
    let (a, b) = tokio::join!(
        request(&app, Method::PUT, &path, &token, Some("0"), body.clone()),
        request(
            &app,
            Method::PUT,
            &path,
            &token,
            Some("0"),
            Some(json!({"value":1}))
        )
    );
    let mut statuses = [a.0, b.0];
    statuses.sort();
    assert_eq!(statuses, [204, 409]);
    // A lost success response must be resolved by GET, not an unconditional retry.
    assert_eq!(
        request(&app, Method::PUT, &path, &token, Some("0"), body)
            .await
            .0,
        409
    );
    assert_eq!(
        request(&app, Method::GET, &path, &token, None, None)
            .await
            .2["revision"],
        1
    );
    let (status, h, _) = request(&app, Method::DELETE, &path, &token, Some("1"), None).await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "2");
    assert_eq!(
        request(&app, Method::GET, &path, &token, None, None)
            .await
            .2,
        json!({"value":null,"reason":null,"revision":2})
    );
    assert_eq!(
        request(&app, Method::DELETE, &path, &token, Some("1"), None)
            .await
            .0,
        409
    );
    let (status, h, _) = request(&app, Method::DELETE, &path, &token, Some("2"), None).await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "2");
}

#[sqlx::test]
async fn stable_reasons_and_parameters_are_validated_on_every_method(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let (article, brief) = identity(&pool, "2026-10-18").await;
    let app = app(pool, &url);
    for (aspect, reason, value) in [
        ("relevance", "more_like_this", 1),
        ("relevance", "not_relevant", -1),
        ("depth", "too_basic", -1),
        ("depth", "too_advanced", -1),
        ("novelty", "already_knew_this", -1),
        ("article_quality", "poor_article", -1),
        ("brief_quality", "inaccurate_summary", -1),
        ("brief_quality", "unclear_summary", -1),
    ] {
        let path = stable_path(
            article,
            aspect,
            (aspect == "brief_quality").then_some(brief),
        );
        let (_, _, saved) = request(&app, Method::GET, &path, &token, None, None).await;
        let revision = saved["revision"].to_string();
        for invalid in [
            json!({"value":-value,"reason":reason}),
            json!({"value":value,"reason":"unknown"}),
            json!({"value":value,"reason":reason,"user_id":"spoof"}),
            json!({"value":0}),
            json!({"value":value,"reason":if aspect=="depth" {"poor_article"} else {"too_basic"}}),
        ] {
            assert_eq!(
                request(
                    &app,
                    Method::PUT,
                    &path,
                    &token,
                    Some(&revision),
                    Some(invalid)
                )
                .await
                .0,
                422
            );
        }
        assert_eq!(
            request(
                &app,
                Method::PUT,
                &path,
                &token,
                Some(&revision),
                Some(json!({"value":value,"reason":reason}))
            )
            .await
            .0,
            204
        );
        assert_eq!(
            request(&app, Method::GET, &path, &token, None, None)
                .await
                .2["reason"],
            reason
        );
    }
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        for path in [
            stable_path(article, "unknown", None),
            stable_path(article, "brief_quality", None),
            stable_path(article, "relevance", Some(brief)),
            format!("{}?user_id=spoof", stable_path(article, "depth", None)),
            format!(
                "{}?brief_id=invalid",
                stable_path(article, "brief_quality", None)
            ),
            format!(
                "{}&brief_id={brief}",
                stable_path(article, "brief_quality", Some(brief))
            ),
        ] {
            let body = (method == Method::PUT).then(|| json!({"value":1}));
            assert!(matches!(
                request(&app, method.clone(), &path, &token, Some("0"), body)
                    .await
                    .0,
                400 | 422
            ));
        }
    }
    let path = stable_path(article, "depth", None);
    for method in [Method::PUT, Method::DELETE] {
        for revision in [None, Some("-1"), Some("bogus"), Some("9223372036854775808")] {
            assert_eq!(
                request(
                    &app,
                    method.clone(),
                    &path,
                    &token,
                    revision,
                    (method == Method::PUT).then(|| json!({"value":1}))
                )
                .await
                .0,
                422
            );
        }
    }
}

#[sqlx::test]
async fn revised_briefs_keep_independent_feedback_and_display_identity(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let (article, original) = identity(&pool, "2026-10-18").await;
    let app = app(pool.clone(), &url);
    let mapping = "/v2/briefs/engineering/2026-10-18/feedback-identity";
    assert_eq!(
        request(&app, Method::GET, mapping, &token, None, None)
            .await
            .2,
        json!({"article_id":article,"brief_id":original})
    );
    let path = stable_path(article, "brief_quality", Some(original));
    assert_eq!(
        request(
            &app,
            Method::PUT,
            &path,
            &token,
            Some("0"),
            Some(json!({"value":-1,"reason":"inaccurate_summary"}))
        )
        .await
        .0,
        204
    );
    let mut intermediate = original;
    for (i, payload) in [
        json!({"deep_dive":"Second","unknown":[1,2]}),
        json!({"deep_dive":"Third","unknown":{"a":true}}),
    ]
    .iter()
    .enumerate()
    {
        sqlx::query("update briefs set payload=$1")
            .bind(payload)
            .execute(&pool)
            .await
            .unwrap();
        let (_, current) = identity(&pool, "2026-10-18").await;
        assert_ne!(current, original);
        if i == 0 {
            intermediate = current;
        }
        let (status, _, displayed) = request(
            &app,
            Method::GET,
            "/v1/briefs/engineering/2026-10-18",
            &token,
            None,
            None,
        )
        .await;
        assert_eq!(status, 200);
        assert_eq!(displayed["payload"], *payload);
        assert_eq!(displayed["article_id"], article.to_string());
        assert_eq!(displayed["brief_id"], current.to_string());
        assert_eq!(
            request(
                &app,
                Method::GET,
                &stable_path(article, "brief_quality", Some(current)),
                &token,
                None,
                None
            )
            .await
            .2,
            json!({"value":null,"reason":null,"revision":0})
        );
        assert_eq!(
            request(&app, Method::GET, PATH, &token, None, None).await.2["brief"],
            json!({"value":null,"revision":0})
        );
        let (status, _, body) = request(&app, Method::GET, mapping, &token, None, None).await;
        assert_eq!(status, 422);
        assert_eq!(body["error"], "mapping_unavailable");
        assert_eq!(
            request(
                &app,
                Method::GET,
                &mapping.replace("feedback-identity", "identity"),
                &token,
                None,
                None
            )
            .await
            .2["brief_id"],
            current.to_string()
        );
    }
    for brief in [original, intermediate] {
        let path = stable_path(article, "brief_quality", Some(brief));
        let (_, _, saved) = request(&app, Method::GET, &path, &token, None, None).await;
        assert_eq!(
            request(
                &app,
                Method::PUT,
                &path,
                &token,
                Some(&saved["revision"].to_string()),
                Some(json!({"value":1}))
            )
            .await
            .0,
            204
        );
    }
    for aspect in ["selection", "brief"] {
        for method in [Method::PUT, Method::DELETE] {
            let path = if method == Method::PUT {
                PATH.to_owned()
            } else {
                format!("{PATH}/{aspect}")
            };
            let (status, _, body) = request(
                &app,
                method.clone(),
                &path,
                &token,
                Some("0"),
                (method == Method::PUT).then(|| json!({"aspect":aspect,"value":1})),
            )
            .await;
            assert_eq!(status, 422);
            assert_eq!(body["error"], "mapping_unavailable");
        }
    }
    assert_eq!(
        request(
            &app,
            Method::GET,
            "/internal/feedback?feed=engineering&since=2026-10-01",
            SERVICE_TOKEN,
            None,
            None
        )
        .await
        .2,
        json!([])
    );
    assert_eq!(
        request(
            &app,
            Method::GET,
            &mapping.replace("2026-10-18", "2026-10-17"),
            &token,
            None,
            None
        )
        .await
        .0,
        404
    );
}

#[sqlx::test]
async fn stable_entitlement_denies_hidden_unrelated_and_revoked_content(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (user, token, _) = setup(&pool).await;
    let (_, outsider) = registered_user(&pool, "outside@example.com", false).await;
    let (article, original) = identity(&pool, "2026-10-18").await;
    let hidden: uuid::Uuid =
        sqlx::query_scalar("insert into feeds(slug,name) values('hidden','Hidden') returning id")
            .fetch_one(&pool)
            .await
            .unwrap();
    sqlx::query("insert into memberships(user_id,feed_id) values($1,$2)")
        .bind(user)
        .bind(hidden)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("insert into briefs(feed_id,date,format,payload,article_url,article_title) values($1,'2026-10-18','insight-brief-v3','{}','https://hidden/article','Hidden')").bind(hidden).execute(&pool).await.unwrap();
    let (hidden_article, hidden_brief): (uuid::Uuid, uuid::Uuid) = sqlx::query_as(
        "select article_id,id from article_briefs where article_url='https://hidden/article'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query("insert into briefs(feed_id,date,format,payload,article_url,article_title) values($1,'2026-10-19','insight-brief-v3','{}','https://e/article','Unpublished to engineering')").bind(hidden).execute(&pool).await.unwrap();
    let hidden_version: uuid::Uuid = sqlx::query_scalar(
        "select id from article_briefs where article_title='Unpublished to engineering'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let app = app(pool.clone(), &url);
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        for (who, path) in [
            (&outsider, stable_path(article, "relevance", None)),
            (&token, stable_path(hidden_article, "relevance", None)),
            (
                &token,
                stable_path(article, "brief_quality", Some(hidden_brief)),
            ),
            (
                &token,
                stable_path(article, "brief_quality", Some(hidden_version)),
            ),
        ] {
            assert_eq!(
                request(
                    &app,
                    method.clone(),
                    &path,
                    who,
                    Some("0"),
                    (method == Method::PUT).then(|| json!({"value":1}))
                )
                .await
                .0,
                403
            );
        }
    }
    for suffix in ["identity", "feedback-identity"] {
        assert_eq!(
            request(
                &app,
                Method::GET,
                &format!("/v2/briefs/engineering/2026-10-18/{suffix}"),
                &outsider,
                None,
                None
            )
            .await
            .0,
            403
        );
    }
    sqlx::query("update briefs set article_url='https://e/replacement' where feed_id<>$1")
        .bind(hidden)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        request(
            &app,
            Method::GET,
            &stable_path(article, "brief_quality", Some(original)),
            &token,
            None,
            None
        )
        .await
        .0,
        200
    );
    sqlx::query("delete from memberships where user_id=$1 and feed_id<>$2")
        .bind(user)
        .bind(hidden)
        .execute(&pool)
        .await
        .unwrap();
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        assert_eq!(
            request(
                &app,
                method.clone(),
                &stable_path(article, "brief_quality", Some(original)),
                &token,
                Some("0"),
                (method == Method::PUT).then(|| json!({"value":1}))
            )
            .await
            .0,
            403
        );
    }
    sqlx::query("update users set is_active=false where id=$1")
        .bind(user)
        .execute(&pool)
        .await
        .unwrap();
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        assert_eq!(
            request(
                &app,
                method.clone(),
                &stable_path(article, "relevance", None),
                &token,
                Some("0"),
                (method == Method::PUT).then(|| json!({"value":1}))
            )
            .await
            .0,
            403
        );
    }
}

#[sqlx::test(migrations = false)]
async fn historic_backfill_keeps_originals_tombstones_and_collision_revisions_on_replay(
    pool: PgPool,
) {
    let migrations = sqlx::migrate!();
    for migration in migrations.iter().filter(|m| m.version <= 6) {
        sqlx::raw_sql(migration.sql.clone())
            .execute(&pool)
            .await
            .unwrap();
    }
    let (user, token) = registered_user(&pool, "history@example.com", false).await;
    let (other, other_token) = registered_user(&pool, "single@example.com", false).await;
    sqlx::raw_sql("insert into feeds(id,slug,name) values('00000000-0000-0000-0000-000000000001','engineering','Engineering'),('00000000-0000-0000-0000-000000000002','hidden','Hidden');
        insert into briefs(feed_id,date,format,payload,article_url,article_title) values
        ('00000000-0000-0000-0000-000000000001','2026-10-18','insight-brief-v3','{}','https://e/article','Article'),
        ('00000000-0000-0000-0000-000000000001','2026-10-19','insight-brief-v3','{}','https://e/article','Article'),
        ('00000000-0000-0000-0000-000000000002','2026-10-19','insight-brief-v3','{}','https://e/article','Article')")
        .execute(&pool).await.unwrap();
    for uid in [user, other] {
        sqlx::query("insert into memberships(user_id,feed_id) values($1,'00000000-0000-0000-0000-000000000001')").bind(uid).execute(&pool).await.unwrap();
    }
    sqlx::query(
        "insert into feedback(user_id,feed_id,date,aspect,value,revision,created_at) values
        ($1,'00000000-0000-0000-0000-000000000001','2026-10-18','selection',1,7,'2026-10-20'),
        ($1,'00000000-0000-0000-0000-000000000001','2026-10-19','selection',-1,2,'2026-10-20'),
        ($1,'00000000-0000-0000-0000-000000000002','2026-10-19','selection',null,3,'2026-10-20'),
        ($1,'00000000-0000-0000-0000-000000000001','2026-10-18','brief',1,9,'2026-10-21'),
        ($1,'00000000-0000-0000-0000-000000000002','2026-10-19','brief',-1,4,'2026-10-20'),
        ($2,'00000000-0000-0000-0000-000000000001','2026-10-18','brief',-1,6,'2026-10-20')",
    )
    .bind(user)
    .bind(other)
    .execute(&pool)
    .await
    .unwrap();
    let (article, original) = identity(&pool, "2026-10-18").await;
    sqlx::query("update briefs set article_url='https://e/replacement',payload='{\"deep_dive\":\"Updated\"}' where feed_id='00000000-0000-0000-0000-000000000001' and date='2026-10-18'").execute(&pool).await.unwrap();
    let before: Value = sqlx::query_scalar(
        "select jsonb_agg(to_jsonb(f) order by user_id,feed_id,date,aspect) from feedback f",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let migration = migrations
        .iter()
        .find(|m| m.version == 7)
        .expect("canonical feedback migration is required");
    sqlx::raw_sql(migration.sql.clone())
        .execute(&pool)
        .await
        .unwrap();
    let (_jwks, url) = jwks_mock().await;
    let app = app(pool.clone(), &url);
    let relevance = stable_path(article, "relevance", None);
    let quality = stable_path(article, "brief_quality", Some(original));
    assert_eq!(
        request(&app, Method::GET, &relevance, &token, None, None)
            .await
            .2,
        json!({"value":null,"reason":null,"revision":8})
    );
    assert_eq!(
        request(&app, Method::GET, &quality, &token, None, None)
            .await
            .2,
        json!({"value":1,"reason":null,"revision":10})
    );
    assert_eq!(
        request(&app, Method::GET, &quality, &other_token, None, None)
            .await
            .2,
        json!({"value":-1,"reason":null,"revision":6})
    );
    // A stale device whose row lost deduplication must not match the new revision.
    assert_eq!(
        request(
            &app,
            Method::PUT,
            &relevance,
            &token,
            Some("7"),
            Some(json!({"value":-1}))
        )
        .await
        .0,
        409
    );
    assert_eq!(
        request(
            &app,
            Method::PUT,
            &relevance,
            &token,
            Some("8"),
            Some(json!({"value":1,"reason":"more_like_this"}))
        )
        .await
        .0,
        204
    );
    sqlx::query("select backfill_article_feedback()")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        request(&app, Method::GET, &relevance, &token, None, None)
            .await
            .2,
        json!({"value":1,"reason":"more_like_this","revision":9})
    );
    assert_eq!(
        request(&app, Method::GET, PATH, &token, None, None).await.2,
        json!({"selection":{"value":null,"revision":0},"brief":{"value":null,"revision":0}})
    );
    let (_, _, export) = request(
        &app,
        Method::GET,
        "/internal/feedback?feed=engineering&since=2026-10-01",
        SERVICE_TOKEN,
        None,
        None,
    )
    .await;
    assert!(export
        .as_array()
        .unwrap()
        .iter()
        .all(|r| r["date"] == "2026-10-19"));
    let after: Value = sqlx::query_scalar(
        "select jsonb_agg(to_jsonb(f) order by user_id,feed_id,date,aspect) from feedback f",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(after, before);
}

#[sqlx::test]
async fn reads_only_current_accounts_feedback(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, a, b) = setup(&pool).await;
    let app = app(pool, &url);
    let (status, _, empty) = request(&app, Method::GET, PATH, &a, None, None).await;
    assert_eq!(status, 200);
    assert_eq!(
        empty,
        json!({"selection":{"value":null,"revision":0},"brief":{"value":null,"revision":0}})
    );
    for (token, value) in [(&a, 1), (&b, -1)] {
        let (status, h, _) = request(
            &app,
            Method::PUT,
            PATH,
            token,
            Some("0"),
            Some(json!({"aspect":"selection","value":value})),
        )
        .await;
        assert_eq!(status, 204);
        assert_eq!(h["x-feedback-revision"], "1");
    }
    let (_, _, mine) = request(&app, Method::GET, PATH, &a, None, None).await;
    assert_eq!(mine["selection"], json!({"value":1,"revision":1}));
    assert_eq!(mine["brief"], json!({"value":null,"revision":0}));
    let (_, _, theirs) = request(&app, Method::GET, PATH, &b, None, None).await;
    assert_eq!(theirs["selection"], json!({"value":-1,"revision":1}));
}

#[sqlx::test]
async fn undo_preserves_revision_and_rejects_stale_resurrection(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool.clone(), &url);
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"brief","value":1}))
        )
        .await
        .0,
        204
    );
    let (status, h, _) = request(
        &app,
        Method::PUT,
        PATH,
        &token,
        Some("1"),
        Some(json!({"aspect":"brief","value":-1})),
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "2");
    let (status, h, _) = request(
        &app,
        Method::DELETE,
        &format!("{PATH}/brief"),
        &token,
        Some("2"),
        None,
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "3");
    let (_, _, body) = request(&app, Method::GET, PATH, &token, None, None).await;
    assert_eq!(body["brief"], json!({"value":null,"revision":3}));
    let (status, h, _) = request(
        &app,
        Method::DELETE,
        &format!("{PATH}/brief"),
        &token,
        Some("3"),
        None,
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "3");
    for revision in ["0", "1", "2"] {
        let (status, _, body) = request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some(revision),
            Some(json!({"aspect":"brief","value":1})),
        )
        .await;
        assert_eq!(status, 409);
        assert_eq!(body["error"], "feedback_conflict");
    }
    let (status, _, body) = request(
        &app,
        Method::GET,
        "/internal/feedback?feed=engineering&since=2026-10-01",
        SERVICE_TOKEN,
        None,
        None,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body, json!([]));
}

#[sqlx::test]
async fn compatibility_writes_advance_revision(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    for (value, revision) in [(1, "1"), (-1, "2")] {
        let (status, h, _) = request(
            &app,
            Method::PUT,
            PATH,
            &token,
            None,
            Some(json!({"aspect":"selection","value":value})),
        )
        .await;
        assert_eq!(status, 204);
        assert_eq!(h["x-feedback-revision"], revision);
    }
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("1"),
            Some(json!({"aspect":"selection","value":1}))
        )
        .await
        .0,
        409
    );
}

#[sqlx::test]
async fn concurrent_first_writes_have_one_winner(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    let (a, b) = tokio::join!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"selection","value":1}))
        ),
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"selection","value":-1}))
        )
    );
    let mut statuses = [a.0, b.0];
    statuses.sort();
    assert_eq!(statuses, [204, 409]);
    let (_, _, saved) = request(&app, Method::GET, PATH, &token, None, None).await;
    assert_eq!(saved["selection"]["revision"], 1);
    assert_eq!(saved["selection"]["value"], if a.0 == 204 { 1 } else { -1 });
}

#[sqlx::test]
async fn absent_record_rejects_nonzero_revision_and_undo_creates_tombstone(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    for method in [Method::PUT, Method::DELETE] {
        let path = if method == Method::PUT {
            PATH.to_owned()
        } else {
            format!("{PATH}/brief")
        };
        let body = if method == Method::PUT {
            Some(json!({"aspect":"brief","value":1}))
        } else {
            None
        };
        assert_eq!(
            request(&app, method, &path, &token, Some("8"), body)
                .await
                .0,
            409
        );
    }
    let (status, h, _) = request(
        &app,
        Method::DELETE,
        &format!("{PATH}/brief"),
        &token,
        Some("0"),
        None,
    )
    .await;
    assert_eq!(status, 204);
    assert_eq!(h["x-feedback-revision"], "1");
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"brief","value":1}))
        )
        .await
        .0,
        409
    );
}

#[sqlx::test]
async fn invalid_mutations_leave_feedback_unchanged(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool, &url);
    for revision in ["-1", "bogus", "1.0", "+1", "9223372036854775808", ""] {
        assert_eq!(
            request(
                &app,
                Method::PUT,
                PATH,
                &token,
                Some(revision),
                Some(json!({"aspect":"brief","value":1}))
            )
            .await
            .0,
            422
        );
    }
    for body in [
        json!({"aspect":"invalid","value":1}),
        json!({"aspect":"brief","value":0}),
    ] {
        assert_eq!(
            request(&app, Method::PUT, PATH, &token, Some("0"), Some(body))
                .await
                .0,
            422
        );
    }
    assert_eq!(
        request(
            &app,
            Method::DELETE,
            &format!("{PATH}/brief"),
            &token,
            None,
            None
        )
        .await
        .0,
        422
    );
    assert_eq!(
        request(
            &app,
            Method::DELETE,
            &format!("{PATH}/invalid"),
            &token,
            Some("0"),
            None
        )
        .await
        .0,
        422
    );
    let (_, _, saved) = request(&app, Method::GET, PATH, &token, None, None).await;
    assert_eq!(saved["brief"]["revision"], 0);
}

#[sqlx::test]
async fn every_operation_enforces_membership_revocation_and_brief_existence(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (uid, token, _) = setup(&pool).await;
    let (_, outsider) = registered_user(&pool, "outsider@example.com", false).await;
    let app = app(pool.clone(), &url);
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        let suffix = if method == Method::DELETE {
            "/brief"
        } else {
            ""
        };
        let body = if method == Method::PUT {
            Some(json!({"aspect":"brief","value":1}))
        } else {
            None
        };
        assert_eq!(
            request(
                &app,
                method.clone(),
                &format!("{PATH}{suffix}"),
                &outsider,
                Some("0"),
                body.clone()
            )
            .await
            .0,
            403
        );
        assert_eq!(
            request(
                &app,
                method,
                &format!("{}{suffix}", PATH.replace("2026-10-18", "2026-10-17")),
                &token,
                Some("0"),
                body
            )
            .await
            .0,
            404
        );
    }
    sqlx::query("update users set is_active=false where id=$1")
        .bind(uid)
        .execute(&pool)
        .await
        .unwrap();
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        let path = if method == Method::DELETE {
            format!("{PATH}/brief")
        } else {
            PATH.to_owned()
        };
        let body = if method == Method::PUT {
            Some(json!({"aspect":"brief","value":1}))
        } else {
            None
        };
        assert_eq!(
            request(&app, method, &path, &token, Some("0"), body)
                .await
                .0,
            403
        );
    }
}

#[sqlx::test]
async fn publication_history_follows_date_corrections_and_deletion(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let (article, original) = identity(&pool, "2026-10-18").await;
    sqlx::query("update briefs set payload='{\"deep_dive\":\"Intermediate\"}'")
        .execute(&pool)
        .await
        .unwrap();
    let (_, intermediate) = identity(&pool, "2026-10-18").await;
    // Changing the date and returning to a previously published version must not collide.
    sqlx::query("update briefs set date='2026-10-20',payload='{}'")
        .execute(&pool)
        .await
        .unwrap();
    let app = app(pool.clone(), &url);
    for brief in [original, intermediate] {
        assert_eq!(
            request(
                &app,
                Method::GET,
                &stable_path(article, "brief_quality", Some(brief)),
                &token,
                None,
                None
            )
            .await
            .0,
            200
        );
    }
    let dates: Vec<chrono::NaiveDate> =
        sqlx::query_scalar("select distinct date from brief_publications")
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        dates,
        vec![chrono::NaiveDate::from_ymd_opt(2026, 10, 20).unwrap()]
    );
    sqlx::query("delete from briefs")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        request(
            &app,
            Method::GET,
            &stable_path(article, "relevance", None),
            &token,
            None,
            None
        )
        .await
        .0,
        403
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("select count(*) from brief_publications")
            .fetch_one(&pool)
            .await
            .unwrap(),
        0
    );
    // A publication removed in the same transaction must not reappear at commit.
    sqlx::raw_sql("begin; insert into briefs(feed_id,date,format,payload,article_url,article_title) select id,'2026-10-21','insight-brief-v3','{}','https://e/article','Article' from feeds; delete from briefs; commit;").execute(&pool).await.unwrap();
    assert_eq!(
        sqlx::query_scalar::<_, i64>("select count(*) from brief_publications")
            .fetch_one(&pool)
            .await
            .unwrap(),
        0
    );
}

#[sqlx::test]
async fn reused_publication_key_does_not_restore_deleted_entitlement(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    sqlx::raw_sql(
        "begin;
        insert into briefs(feed_id,date,format,payload,article_url,article_title)
            select id,'2026-10-19','insight-brief-v3','{}','https://e/deleted','Deleted' from feeds;
        delete from briefs where date='2026-10-19';
        insert into briefs(feed_id,date,format,payload,article_url,article_title)
            select id,'2026-10-19','insight-brief-v3','{}','https://e/replacement','Replacement' from feeds;
        set constraints all immediate;
        commit;",
    )
    .execute(&pool)
    .await
    .unwrap();
    let (deleted_article, deleted_brief): (uuid::Uuid, uuid::Uuid) = sqlx::query_as(
        "select article_id,id from article_briefs where article_url='https://e/deleted'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    let (current_article, current_brief) = identity(&pool, "2026-10-19").await;
    let app = app(pool, &url);
    for (article, brief, status) in [
        (deleted_article, deleted_brief, 403),
        (current_article, current_brief, 200),
    ] {
        for path in [
            stable_path(article, "relevance", None),
            stable_path(article, "brief_quality", Some(brief)),
        ] {
            assert_eq!(
                request(&app, Method::GET, &path, &token, None, None)
                    .await
                    .0,
                status,
            );
        }
    }
}

#[sqlx::test]
async fn displayed_payload_and_identity_remain_atomic_during_publication(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let app = app(pool.clone(), &url);
    let writer = async {
        for revision in 0..40 {
            sqlx::query("update briefs set payload=$1,article_title=$2,article_url=$3,model=$2,eval_score=$4")
                .bind(json!({"deep_dive":format!("Version {revision}"),"extra":[revision]}))
                .bind(format!("Title {revision}")).bind(format!("https://e/{revision}"))
                .bind(f64::from(revision)/100.0).execute(&pool).await.unwrap();
        }
    };
    let reader = async {
        for _ in 0..40 {
            let (status, _, body) = request(
                &app,
                Method::GET,
                "/v1/briefs/engineering/2026-10-18",
                &token,
                None,
                None,
            )
            .await;
            assert_eq!(status, 200);
            let expected:Value=sqlx::query_scalar("select jsonb_build_object('article_id',article_id,'brief_id',id,'payload',payload,'article_url',article_url,'article_title',article_title,'format',format,'model',model,'eval_score',eval_score) from article_briefs where id=$1")
                .bind(uuid::Uuid::parse_str(body["brief_id"].as_str().unwrap()).unwrap()).fetch_one(&pool).await.unwrap();
            for (key, value) in expected.as_object().unwrap() {
                if key == "eval_score" {
                    assert_eq!(body[key].as_f64(), value.as_f64());
                } else {
                    assert_eq!(&body[key], value, "{key}");
                }
            }
        }
    };
    tokio::join!(writer, reader);
}

#[sqlx::test]
async fn stable_existing_vote_race_and_initial_undo_preserve_revision_barriers(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let (article, _) = identity(&pool, "2026-10-18").await;
    let app = app(pool, &url);
    let path = stable_path(article, "novelty", None);
    let (status, headers, _) = request(&app, Method::DELETE, &path, &token, Some("0"), None).await;
    assert_eq!(status, 204);
    assert_eq!(headers["x-feedback-revision"], "1");
    assert_eq!(
        request(
            &app,
            Method::PUT,
            &path,
            &token,
            Some("0"),
            Some(json!({"value":-1,"reason":"already_knew_this"}))
        )
        .await
        .0,
        409
    );
    let path = stable_path(article, "article_quality", None);
    assert_eq!(
        request(
            &app,
            Method::PUT,
            &path,
            &token,
            Some("0"),
            Some(json!({"value":1,"reason":null}))
        )
        .await
        .0,
        204
    );
    let (changed, undone) = tokio::join!(
        request(
            &app,
            Method::PUT,
            &path,
            &token,
            Some("1"),
            Some(json!({"value":-1,"reason":"poor_article"}))
        ),
        request(&app, Method::DELETE, &path, &token, Some("1"), None)
    );
    let mut statuses = [changed.0, undone.0];
    statuses.sort();
    assert_eq!(statuses, [204, 409]);
    let saved = request(&app, Method::GET, &path, &token, None, None)
        .await
        .2;
    let expected = if changed.0 == 204 {
        json!({"value":-1,"reason":"poor_article","revision":2})
    } else {
        json!({"value":null,"reason":null,"revision":2})
    };
    assert_eq!(saved, expected);
}

#[sqlx::test]
async fn missing_mapping_and_disabled_feed_do_not_grant_feedback_access(pool: PgPool) {
    let (_jwks, url) = jwks_mock().await;
    let (_, token, _) = setup(&pool).await;
    let (article, _) = identity(&pool, "2026-10-18").await;
    let app = app(pool.clone(), &url);
    sqlx::query("update feeds set is_active=false")
        .execute(&pool)
        .await
        .unwrap();
    for method in [Method::GET, Method::PUT, Method::DELETE] {
        assert_eq!(
            request(
                &app,
                method.clone(),
                &stable_path(article, "relevance", None),
                &token,
                Some("0"),
                (method == Method::PUT).then(|| json!({"value":1}))
            )
            .await
            .0,
            403
        );
    }
    sqlx::query("update feeds set is_active=true")
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("delete from legacy_brief_identity")
        .execute(&pool)
        .await
        .unwrap();
    for suffix in ["identity", "feedback-identity"] {
        assert_eq!(
            request(
                &app,
                Method::GET,
                &format!("/v2/briefs/engineering/2026-10-18/{suffix}"),
                &token,
                None,
                None
            )
            .await
            .0,
            404
        );
    }
    assert_eq!(
        request(
            &app,
            Method::PUT,
            PATH,
            &token,
            Some("0"),
            Some(json!({"aspect":"brief","value":1}))
        )
        .await
        .0,
        404
    );
    assert_eq!(
        request(
            &app,
            Method::GET,
            &stable_path(article, "relevance", None),
            &token,
            None,
            None
        )
        .await
        .0,
        403
    );
}
