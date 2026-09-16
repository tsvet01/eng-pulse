use pulse_api::seed::{apply, SourceEntry};
use sqlx::PgPool;

#[sqlx::test]
async fn seed_is_idempotent(pool: PgPool) {
    let src = vec![
        SourceEntry {
            name: "One".into(),
            r#type: "rss".into(),
            url: "https://a/feed".into(),
        },
        SourceEntry {
            name: "HN".into(),
            r#type: "hackernews".into(),
            url: "https://hn/top".into(),
        },
    ];
    let s1 = apply(&pool, &src, "FRIENDS", 5).await.unwrap();
    let s2 = apply(&pool, &src[..1], "FRIENDS", 5).await.unwrap();
    assert_eq!((s1.sources_active, s2.sources_active), (2, 1));
    let feeds: i64 = sqlx::query_scalar("select count(*) from feeds where slug = 'engineering'")
        .fetch_one(&pool)
        .await
        .unwrap();
    let invites: i64 = sqlx::query_scalar("select count(*) from invites where code = 'FRIENDS'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!((feeds, invites), (1, 1));
    let inactive: i64 = sqlx::query_scalar("select count(*) from feed_sources where not is_active")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(inactive, 1);
}
