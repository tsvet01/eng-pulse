mod common;
use axum::http::Method;
use common::*;
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

const FEEDBACK: &str = "/v1/briefs/engineering/2026-10-18/feedback";

async fn fixture(pool: &PgPool) -> (Uuid, Uuid, String, String) {
    let fid = engineering_feed(pool).await;
    let (uid, a) = registered_user(pool, "a@example.com", false).await;
    let (other, b) = registered_user(pool, "b@example.com", false).await;
    for id in [uid, other] {
        sqlx::query("insert into memberships (user_id, feed_id, role) values ($1, $2, 'owner')")
            .bind(id)
            .bind(fid)
            .execute(pool)
            .await
            .unwrap();
    }
    sqlx::query("insert into briefs (feed_id, date, format, payload, article_url, article_title, model, eval_score) values ($1, '2026-10-18', 'insight-brief-v3', '{}', 'https://example.com', 'Title', 'test', 0.9)")
        .bind(fid).execute(pool).await.unwrap();
    (fid, uid, a, b)
}

#[sqlx::test]
async fn feedback_is_private_and_deletion_is_scoped_and_idempotent(pool: PgPool) {
    let (_server, url) = jwks_mock().await;
    let (_, _, a, b) = fixture(&pool).await;
    let app = app(pool, &url);
    assert_eq!(
        send(&app, Method::GET, FEEDBACK, Some(&a), None).await,
        (200, json!({"selection": null, "brief": null}))
    );
    for (token, aspect, value) in [
        (&a, "selection", 1),
        (&a, "brief", -1),
        (&b, "selection", -1),
    ] {
        assert_eq!(
            send(
                &app,
                Method::PUT,
                FEEDBACK,
                Some(token),
                Some(json!({"aspect": aspect, "value": value}))
            )
            .await
            .0,
            204
        );
    }
    assert_eq!(
        send(&app, Method::GET, FEEDBACK, Some(&a), None).await.1,
        json!({"selection": 1, "brief": -1})
    );
    for _ in 0..2 {
        assert_eq!(
            send(
                &app,
                Method::DELETE,
                FEEDBACK,
                Some(&a),
                Some(json!({"aspect": "selection"}))
            )
            .await
            .0,
            204
        );
    }
    assert_eq!(
        send(&app, Method::GET, FEEDBACK, Some(&a), None).await.1,
        json!({"selection": null, "brief": -1})
    );
    assert_eq!(
        send(&app, Method::GET, FEEDBACK, Some(&b), None).await.1,
        json!({"selection": -1, "brief": null})
    );
}

#[sqlx::test]
async fn preferences_are_private_and_cannot_recreate_membership(pool: PgPool) {
    let (_server, url) = jwks_mock().await;
    let (fid, uid, a, b) = fixture(&pool).await;
    let app = app(pool.clone(), &url);
    let path = format!("/v1/feeds/{fid}/preferences");
    assert_eq!(
        send(&app, Method::GET, &path, Some(&a), None).await,
        (200, json!({"notify_email": true, "notify_push": true}))
    );
    assert_eq!(
        send(
            &app,
            Method::PUT,
            &path,
            Some(&a),
            Some(json!({"notify_email": false, "notify_push": false}))
        )
        .await,
        (200, json!({"notify_email": false, "notify_push": false}))
    );
    assert_eq!(
        send(&app, Method::GET, &path, Some(&b), None).await.1,
        json!({"notify_email": true, "notify_push": true})
    );
    let role: String =
        sqlx::query_scalar("select role from memberships where user_id=$1 and feed_id=$2")
            .bind(uid)
            .bind(fid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(role, "owner");
    for body in [
        json!({"notify_email": true}),
        json!({"notify_email": "yes", "notify_push": false}),
    ] {
        assert_eq!(
            send(&app, Method::PUT, &path, Some(&a), Some(body)).await.0,
            422
        );
    }
    pulse_api::db::feeds::delete_membership(&pool, uid, fid)
        .await
        .unwrap();
    for method in [Method::GET, Method::PUT] {
        assert_eq!(
            send(
                &app,
                method,
                &path,
                Some(&a),
                Some(json!({"notify_email": true, "notify_push": true}))
            )
            .await
            .0,
            403
        );
    }
    assert!(!pulse_api::db::feeds::is_member(&pool, uid, fid)
        .await
        .unwrap());
}

#[sqlx::test]
async fn all_personal_routes_enforce_access(pool: PgPool) {
    let (_server, url) = jwks_mock().await;
    let (fid, uid, a, _) = fixture(&pool).await;
    let (_, outsider) = registered_user(&pool, "outsider@example.com", true).await;
    let app = app(pool.clone(), &url);
    let prefs = format!("/v1/feeds/{fid}/preferences");
    let requests = [
        (Method::GET, FEEDBACK, None),
        (
            Method::PUT,
            FEEDBACK,
            Some(json!({"aspect": "brief", "value": 1})),
        ),
        (Method::DELETE, FEEDBACK, Some(json!({"aspect": "brief"}))),
        (Method::GET, prefs.as_str(), None),
        (
            Method::PUT,
            prefs.as_str(),
            Some(json!({"notify_email": false, "notify_push": false})),
        ),
    ];
    for (method, path, body) in &requests {
        assert_eq!(
            send(&app, method.clone(), path, None, body.clone()).await.0,
            401
        );
        assert_eq!(
            send(&app, method.clone(), path, Some(&outsider), body.clone())
                .await
                .0,
            403
        );
    }
    sqlx::query("update users set is_active=false where id=$1")
        .bind(uid)
        .execute(&pool)
        .await
        .unwrap();
    for (method, path, body) in &requests {
        assert_eq!(
            send(&app, method.clone(), path, Some(&a), body.clone())
                .await
                .0,
            403
        );
    }
    sqlx::query("update users set is_active=true where id=$1")
        .bind(uid)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query("update feeds set is_active=false where id=$1")
        .bind(fid)
        .execute(&pool)
        .await
        .unwrap();
    for (method, path, body) in &requests {
        assert_eq!(
            send(&app, method.clone(), path, Some(&a), body.clone())
                .await
                .0,
            404
        );
    }
}

#[sqlx::test]
async fn feedback_rejects_invalid_input_and_missing_brief(pool: PgPool) {
    let (_server, url) = jwks_mock().await;
    let (_, _, a, _) = fixture(&pool).await;
    let app = app(pool, &url);
    for body in [
        json!({"aspect": "other", "value": 1}),
        json!({"aspect": "brief", "value": 0}),
    ] {
        assert_eq!(
            send(&app, Method::PUT, FEEDBACK, Some(&a), Some(body))
                .await
                .0,
            422
        );
    }
    assert_eq!(
        send(
            &app,
            Method::DELETE,
            FEEDBACK,
            Some(&a),
            Some(json!({"aspect": "other"}))
        )
        .await
        .0,
        422
    );
    for (date, expected) in [("bad", 422), ("2026-10-19", 404)] {
        for method in [Method::GET, Method::DELETE] {
            assert_eq!(
                send(
                    &app,
                    method,
                    &format!("/v1/briefs/engineering/{date}/feedback"),
                    Some(&a),
                    Some(json!({"aspect": "brief"}))
                )
                .await
                .0,
                expected
            );
        }
    }
}
