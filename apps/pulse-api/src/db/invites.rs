use chrono::{DateTime, Utc};
use rand::RngExt;
use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow, serde::Serialize)]
pub struct Invite {
    pub code: String,
    pub max_uses: i32,
    pub used_count: i32,
    pub expires_at: Option<DateTime<Utc>>,
}

/// Atomically consumes one use; None when the code is missing, expired or exhausted.
pub async fn consume(
    tx: &mut Transaction<'_, Postgres>,
    code: &str,
) -> sqlx::Result<Option<Invite>> {
    sqlx::query_as("update invites set used_count = used_count + 1 where code = $1 and used_count < max_uses and (expires_at is null or expires_at > now()) returning code, max_uses, used_count, expires_at")
        .bind(code).fetch_optional(&mut **tx).await
}

fn new_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();
    (0..12)
        .map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char)
        .collect()
}

pub async fn create(
    pool: &PgPool,
    created_by: Uuid,
    max_uses: i32,
    expires_at: Option<DateTime<Utc>>,
) -> sqlx::Result<Invite> {
    sqlx::query_as("insert into invites (code, created_by, max_uses, expires_at) values ($1, $2, $3, $4) returning code, max_uses, used_count, expires_at")
        .bind(new_code()).bind(created_by).bind(max_uses).bind(expires_at).fetch_one(pool).await
}
