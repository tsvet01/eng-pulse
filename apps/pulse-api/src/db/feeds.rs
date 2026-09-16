use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
pub struct FeedRow {
    pub id: Uuid,
    pub slug: String,
    pub name: String,
    pub description: Option<String>,
    pub is_active: bool,
    pub role: Option<String>,
}

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct SourceRow {
    pub url: String,
    pub kind: String,
}

pub async fn list_for_user(pool: &PgPool, user_id: Uuid) -> sqlx::Result<Vec<FeedRow>> {
    sqlx::query_as("select f.id, f.slug, f.name, f.description, f.is_active, m.role from feeds f left join memberships m on m.feed_id = f.id and m.user_id = $1 where f.is_active order by f.slug")
        .bind(user_id).fetch_all(pool).await
}

pub async fn topics(pool: &PgPool, feed_id: Uuid) -> sqlx::Result<Vec<String>> {
    sqlx::query_scalar("select topic from feed_topics where feed_id = $1 order by topic")
        .bind(feed_id)
        .fetch_all(pool)
        .await
}

pub async fn sources(pool: &PgPool, feed_id: Uuid) -> sqlx::Result<Vec<SourceRow>> {
    sqlx::query_as(
        "select url, kind from feed_sources where feed_id = $1 and is_active order by url",
    )
    .bind(feed_id)
    .fetch_all(pool)
    .await
}

pub async fn create(
    pool: &PgPool,
    user_id: Uuid,
    slug: &str,
    name: &str,
    description: Option<&str>,
) -> sqlx::Result<Uuid> {
    let mut tx = pool.begin().await?;
    let id: Uuid = sqlx::query_scalar("insert into feeds (slug, name, description, created_by) values ($1, $2, $3, $4) returning id")
        .bind(slug).bind(name).bind(description).bind(user_id).fetch_one(&mut *tx).await?;
    sqlx::query("insert into memberships (user_id, feed_id, role) values ($1, $2, 'owner')")
        .bind(user_id)
        .bind(id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(id)
}

pub async fn exists(pool: &PgPool, feed_id: Uuid) -> sqlx::Result<bool> {
    sqlx::query_scalar("select exists(select 1 from feeds where id = $1 and is_active)")
        .bind(feed_id)
        .fetch_one(pool)
        .await
}

pub async fn is_member(pool: &PgPool, user_id: Uuid, feed_id: Uuid) -> sqlx::Result<bool> {
    sqlx::query_scalar(
        "select exists(select 1 from memberships where user_id = $1 and feed_id = $2)",
    )
    .bind(user_id)
    .bind(feed_id)
    .fetch_one(pool)
    .await
}

pub async fn upsert_membership(
    pool: &PgPool,
    user_id: Uuid,
    feed_id: Uuid,
    notify_email: Option<bool>,
    notify_push: Option<bool>,
) -> sqlx::Result<()> {
    sqlx::query("insert into memberships (user_id, feed_id, notify_email, notify_push) values ($1, $2, coalesce($3, true), coalesce($4, true)) on conflict (user_id, feed_id) do update set notify_email = coalesce($3, memberships.notify_email), notify_push = coalesce($4, memberships.notify_push)")
        .bind(user_id).bind(feed_id).bind(notify_email).bind(notify_push).execute(pool).await.map(|_| ())
}

pub async fn delete_membership(pool: &PgPool, user_id: Uuid, feed_id: Uuid) -> sqlx::Result<()> {
    sqlx::query("delete from memberships where user_id = $1 and feed_id = $2")
        .bind(user_id)
        .bind(feed_id)
        .execute(pool)
        .await
        .map(|_| ())
}

pub async fn add_topic(
    pool: &PgPool,
    feed_id: Uuid,
    topic: &str,
    user_id: Uuid,
) -> sqlx::Result<()> {
    sqlx::query(
        "insert into feed_topics (feed_id, topic, added_by) values ($1, $2, $3) on conflict do nothing",
    )
    .bind(feed_id)
    .bind(topic)
    .bind(user_id)
    .execute(pool)
    .await
    .map(|_| ())
}

pub async fn remove_topic(pool: &PgPool, feed_id: Uuid, topic: &str) -> sqlx::Result<()> {
    sqlx::query("delete from feed_topics where feed_id = $1 and topic = $2")
        .bind(feed_id)
        .bind(topic)
        .execute(pool)
        .await
        .map(|_| ())
}

pub async fn add_source(
    pool: &PgPool,
    feed_id: Uuid,
    url: &str,
    kind: &str,
    user_id: Uuid,
) -> sqlx::Result<()> {
    sqlx::query("insert into feed_sources (feed_id, url, kind, added_by) values ($1, $2, $3, $4) on conflict (feed_id, url) do update set is_active = true, kind = excluded.kind")
        .bind(feed_id).bind(url).bind(kind).bind(user_id).execute(pool).await.map(|_| ())
}

pub async fn remove_source(pool: &PgPool, feed_id: Uuid, url: &str) -> sqlx::Result<()> {
    sqlx::query("update feed_sources set is_active = false where feed_id = $1 and url = $2")
        .bind(feed_id)
        .bind(url)
        .execute(pool)
        .await
        .map(|_| ())
}
