use sqlx::PgPool;

// Placeholder.
pub async fn run(_pool: &PgPool, _args: &[String]) -> Result<(), String> {
    Err("seed not implemented".into())
}
