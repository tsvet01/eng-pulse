use sqlx::PgPool;

// Placeholder until Task 8 fills in seeding.
pub async fn run(_pool: &PgPool, _args: &[String]) -> Result<(), String> {
    Err("seed not implemented".into())
}
