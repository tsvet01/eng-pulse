mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;

#[sqlx::test]
async fn pilot_configuration_is_read_only_for_every_role(pool: PgPool) {
    let (server, url) = jwks_mock().await;
    let fid = engineering_feed(&pool).await;
    sqlx::query("insert into feed_topics (feed_id, topic) values ($1, 'rust')")
        .bind(fid)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("insert into feed_sources (feed_id, url, kind) values ($1, 'https://example.com/feed', 'rss')").bind(fid).execute(&pool).await.unwrap();
    let app = app(pool.clone(), &url);
    for (email, role, admin) in [
        ("owner@example.com", Some("owner"), false),
        ("member@example.com", Some("member"), false),
        ("admin@example.com", None, true),
        ("stranger@example.com", None, false),
    ] {
        let (uid, t) = registered_user(&pool, email, admin).await;
        if let Some(role) = role {
            sqlx::query("insert into memberships (user_id, feed_id, role) values ($1, $2, $3)")
                .bind(uid)
                .bind(fid)
                .bind(role)
                .execute(&pool)
                .await
                .unwrap();
        }
        for (method, path, body) in [
            (
                Method::POST,
                "/v1/feeds".into(),
                Some(json!({"slug": "extra", "name": "Extra"})),
            ),
            (
                Method::POST,
                format!("/v1/feeds/{fid}/topics"),
                Some(json!({"topic": "ai"})),
            ),
            (Method::DELETE, format!("/v1/feeds/{fid}/topics/rust"), None),
            (
                Method::POST,
                format!("/v1/feeds/{fid}/sources"),
                Some(json!({"url": format!("{}/untrusted-feed", server.uri())})),
            ),
            (
                Method::DELETE,
                format!("/v1/feeds/{fid}/sources?url=https://example.com/feed"),
                None,
            ),
        ] {
            assert_eq!(
                send(&app, method, &path, Some(&t), body).await.0,
                403,
                "{email}: {path}"
            );
        }
    }
    let n: i64 = sqlx::query_scalar("select count(*) from feeds")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(n, 1);
    assert_eq!(
        pulse_api::db::feeds::topics(&pool, fid).await.unwrap(),
        ["rust"]
    );
    assert_eq!(
        pulse_api::db::feeds::sources(&pool, fid)
            .await
            .unwrap()
            .len(),
        1
    );
    assert!(server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .all(|r| r.url.path() == "/jwks"));
    assert_eq!(
        send(&app, Method::POST, "/v1/feeds", None, Some(json!({})))
            .await
            .0,
        401
    );
}

#[sqlx::test]
async fn only_active_engineering_is_visible_joinable_and_readable(pool: PgPool) {
    let (_s, url) = jwks_mock().await;
    let fid = engineering_feed(&pool).await;
    let other: uuid::Uuid =
        sqlx::query_scalar("insert into feeds (slug, name) values ('other', 'Other') returning id")
            .fetch_one(&pool)
            .await
            .unwrap();
    let (uid, t) = registered_user(&pool, "reader@example.com", false).await;
    // Even stale memberships must not expose feeds outside the pilot.
    sqlx::query("insert into memberships (user_id, feed_id) values ($1, $2)")
        .bind(uid)
        .bind(other)
        .execute(&pool)
        .await
        .unwrap();
    let app = app(pool.clone(), &url);
    for auth in [&t, SERVICE_TOKEN] {
        let path = if auth == t {
            "/v1/feeds"
        } else {
            "/internal/feeds"
        };
        let (status, body) = send(&app, Method::GET, path, Some(auth), None).await;
        assert_eq!(status, 200);
        assert_eq!(body.as_array().unwrap().len(), 1);
        assert_eq!(body[0]["slug"], "engineering");
    }
    assert_eq!(
        send(
            &app,
            Method::POST,
            &format!("/v1/feeds/{fid}/membership"),
            Some(&t),
            Some(json!({"notify_push": false}))
        )
        .await
        .0,
        200
    );
    assert_eq!(
        send(
            &app,
            Method::POST,
            &format!("/v1/feeds/{fid}/membership"),
            Some(&t),
            Some(json!({"notify_email": false}))
        )
        .await
        .0,
        200
    );
    let prefs: (bool, bool) = sqlx::query_as(
        "select notify_email, notify_push from memberships where user_id = $1 and feed_id = $2",
    )
    .bind(uid)
    .bind(fid)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(prefs, (false, false));
    for id in [other, uuid::Uuid::new_v4()] {
        assert_eq!(
            send(
                &app,
                Method::POST,
                &format!("/v1/feeds/{id}/membership"),
                Some(&t),
                None
            )
            .await
            .0,
            404
        );
        assert_eq!(
            send(
                &app,
                Method::GET,
                &format!("/v1/feeds/{id}/briefs"),
                Some(&t),
                None
            )
            .await
            .0,
            404
        );
    }
    assert_eq!(
        send(
            &app,
            Method::GET,
            "/v1/briefs/other/2026-10-13",
            Some(&t),
            None
        )
        .await
        .0,
        404
    );
    sqlx::query("update feeds set is_active = false where id = $1")
        .bind(fid)
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(
        send(
            &app,
            Method::POST,
            &format!("/v1/feeds/{fid}/membership"),
            Some(&t),
            None
        )
        .await
        .0,
        404
    );
    assert_eq!(
        send(
            &app,
            Method::GET,
            "/v1/briefs/engineering/2026-10-13",
            Some(&t),
            None
        )
        .await
        .0,
        404
    );
    assert_eq!(
        send(
            &app,
            Method::GET,
            "/internal/feeds",
            Some(SERVICE_TOKEN),
            None
        )
        .await
        .1,
        json!([])
    );
}
