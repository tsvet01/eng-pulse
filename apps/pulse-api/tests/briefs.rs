mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

async fn feed_with_briefs(pool: &PgPool, user_id: uuid::Uuid) -> uuid::Uuid {
    let id: uuid::Uuid = sqlx::query_scalar(
        "insert into feeds (slug, name) values ('engineering','E') returning id",
    )
    .fetch_one(pool)
    .await
    .unwrap();
    sqlx::query("insert into memberships (user_id, feed_id) values ($1, $2)")
        .bind(user_id)
        .bind(id)
        .execute(pool)
        .await
        .unwrap();
    for d in ["2026-09-14", "2026-09-15", "2026-09-16"] {
        sqlx::query("insert into briefs (feed_id, date, format, payload, article_url, article_title, model, eval_score) values ($1, $2::date, 'insight-brief-v3', $3, 'https://e/x', $2, 'claude-opus-5', 0.9)")
            .bind(id).bind(d).bind(json!({"key_idea": format!("idea {d}"), "why_it_matters": "w", "what_to_change": null, "deep_dive": "d", "meta": null})).execute(pool).await.unwrap();
    }
    id
}

#[sqlx::test]
async fn list_paginates_and_requires_membership(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    let (_, stranger) = registered_user(&pool, "s@example.com", false).await;
    let id = feed_with_briefs(&pool, uid).await;
    let app = app(pool, &url);
    let (status, body) = send(
        &app,
        Method::GET,
        &format!("/v1/feeds/{id}/briefs?limit=2"),
        Some(&t),
        None,
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body.as_array().unwrap().len(), 2);
    assert_eq!(body[0]["date"], "2026-09-16");
    assert_eq!(body[0]["snippet"], "idea 2026-09-16");
    let (_, body) = send(
        &app,
        Method::GET,
        &format!("/v1/feeds/{id}/briefs?before=2026-09-15"),
        Some(&t),
        None,
    )
    .await;
    assert_eq!(body.as_array().unwrap().len(), 1);
    let (status, _) = send(
        &app,
        Method::GET,
        &format!("/v1/feeds/{id}/briefs"),
        Some(&stranger),
        None,
    )
    .await;
    assert_eq!(status, 403);
}

#[sqlx::test]
async fn get_brief_returns_contract_shape(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    feed_with_briefs(&pool, uid).await;
    let app = app(pool, &url);
    let (status, body) = send(
        &app,
        Method::GET,
        "/v1/briefs/engineering/2026-09-15",
        Some(&t),
        None,
    )
    .await;
    assert_eq!(status, 200);
    let b: pulse_core::Brief = serde_json::from_value(body).unwrap();
    assert_eq!(b.payload.key_idea, "idea 2026-09-15");
    assert_eq!(b.feed_slug, "engineering");
    let (status, _) = send(
        &app,
        Method::GET,
        "/v1/briefs/engineering/2026-01-01",
        Some(&t),
        None,
    )
    .await;
    assert_eq!(status, 404);
}

#[sqlx::test]
async fn feedback_upserts(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    let fid = feed_with_briefs(&pool, uid).await;
    let app = app(pool.clone(), &url);
    for v in [1, -1] {
        let (status, _) = send(
            &app,
            Method::PUT,
            "/v1/briefs/engineering/2026-09-15/feedback",
            Some(&t),
            Some(json!({"aspect": "brief", "value": v})),
        )
        .await;
        assert_eq!(status, 204);
    }
    let v: i16 =
        sqlx::query_scalar("select value from feedback where user_id = $1 and feed_id = $2")
            .bind(uid)
            .bind(fid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(v, -1);
    let (status, _) = send(
        &app,
        Method::PUT,
        "/v1/briefs/engineering/2026-09-15/feedback",
        Some(&t),
        Some(json!({"aspect": "tone", "value": 1})),
    )
    .await;
    assert_eq!(status, 422);
}

#[sqlx::test]
async fn feedback_requires_existing_brief(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let (uid, t) = registered_user(&pool, "m@example.com", false).await;
    feed_with_briefs(&pool, uid).await;
    let app = app(pool, &url);
    let (status, _) = send(
        &app,
        Method::PUT,
        "/v1/briefs/engineering/2026-01-01/feedback",
        Some(&t),
        Some(json!({"aspect": "brief", "value": 1})),
    )
    .await;
    assert_eq!(status, 404);
}
