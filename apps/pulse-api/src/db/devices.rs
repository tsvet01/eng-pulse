use sqlx::PgPool;
use uuid::Uuid;

pub async fn upsert(
    pool: &PgPool,
    user_id: Uuid,
    platform: &str,
    token: &str,
    app_version: Option<&str>,
) -> sqlx::Result<()> {
    sqlx::query("insert into device_tokens (user_id, platform, token, app_version) values ($1,$2,$3,$4) on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, app_version = excluded.app_version, is_active = true, updated_at = now()")
        .bind(user_id).bind(platform).bind(token).bind(app_version).execute(pool).await.map(|_| ())
}

pub async fn deactivate(pool: &PgPool, user_id: Uuid, token: &str) -> sqlx::Result<()> {
    sqlx::query("update device_tokens set is_active = false, updated_at = now() where user_id = $1 and token = $2").bind(user_id).bind(token).execute(pool).await.map(|_| ())
}
