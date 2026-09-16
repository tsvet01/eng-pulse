use sqlx::{PgPool, Postgres, Transaction};
use uuid::Uuid;

#[derive(Debug, Clone, sqlx::FromRow, serde::Serialize)]
pub struct User {
    pub id: Uuid,
    pub email: String,
    pub display_name: Option<String>,
    pub is_admin: bool,
}

pub async fn find_by_identity(
    pool: &PgPool,
    issuer: &str,
    subject: &str,
) -> sqlx::Result<Option<User>> {
    sqlx::query_as("select u.id, u.email::text as email, u.display_name, u.is_admin from users u join identities i on i.user_id = u.id where i.issuer = $1 and i.subject = $2")
        .bind(issuer).bind(subject).fetch_optional(pool).await
}

pub async fn find_by_email(pool: &PgPool, email: &str) -> sqlx::Result<Option<User>> {
    sqlx::query_as("select id, email::text as email, display_name, is_admin from users where email = $1::citext")
        .bind(email).fetch_optional(pool).await
}

/// Same lookup as `find_by_email`, but run on the caller's open transaction
/// instead of a separate pool connection, so sign-up reads and writes the
/// `users` row as one atomic unit. Two concurrent sign-ups can still both
/// miss here and race to insert; the caller must handle the resulting unique
/// violation.
pub async fn find_by_email_tx(
    tx: &mut Transaction<'_, Postgres>,
    email: &str,
) -> sqlx::Result<Option<User>> {
    sqlx::query_as("select id, email::text as email, display_name, is_admin from users where email = $1::citext")
        .bind(email).fetch_optional(&mut **tx).await
}

pub async fn insert_user(
    tx: &mut Transaction<'_, Postgres>,
    email: &str,
    is_admin: bool,
) -> sqlx::Result<User> {
    sqlx::query_as("insert into users (email, is_admin) values ($1, $2) returning id, email::text as email, display_name, is_admin")
        .bind(email).bind(is_admin).fetch_one(&mut **tx).await
}

pub async fn insert_identity(
    tx: &mut Transaction<'_, Postgres>,
    user_id: Uuid,
    issuer: &str,
    subject: &str,
) -> sqlx::Result<()> {
    sqlx::query("insert into identities (user_id, issuer, subject) values ($1, $2, $3)")
        .bind(user_id)
        .bind(issuer)
        .bind(subject)
        .execute(&mut **tx)
        .await
        .map(|_| ())
}
