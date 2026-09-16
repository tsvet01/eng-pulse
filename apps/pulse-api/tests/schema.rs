use sqlx::PgPool;

#[sqlx::test]
async fn schema_has_all_tables(pool: PgPool) {
    let names: Vec<String> = sqlx::query_scalar(
        "select table_name::text from information_schema.tables where table_schema='public' and table_name <> '_sqlx_migrations' order by 1",
    )
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(
        names,
        [
            "briefs",
            "device_tokens",
            "feed_sources",
            "feed_topics",
            "feedback",
            "feeds",
            "identities",
            "invites",
            "memberships",
            "notifications_sent",
            "runs",
            "users"
        ]
    );
}

#[sqlx::test]
async fn briefs_upsert_on_feed_and_date(pool: PgPool) {
    let feed: uuid::Uuid =
        sqlx::query_scalar("insert into feeds (slug, name) values ('t','T') returning id")
            .fetch_one(&pool)
            .await
            .unwrap();
    for title in ["a", "b"] {
        sqlx::query("insert into briefs (feed_id, date, format, payload, article_url, article_title) values ($1, '2026-09-16', 'insight-brief-v3', '{}', 'u', $2) on conflict (feed_id, date) do update set article_title = excluded.article_title")
            .bind(feed).bind(title).execute(&pool).await.unwrap();
    }
    let t: String = sqlx::query_scalar("select article_title from briefs")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(t, "b");
}
