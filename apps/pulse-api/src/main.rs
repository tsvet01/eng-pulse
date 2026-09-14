mod health;

use axum::{routing::get, Router};
use sqlx::postgres::PgPoolOptions;
use tracing::info;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .json()
        .init();

    let database_url = std::env::var("DATABASE_URL")?;
    let bind = std::env::var("BIND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".into());

    let pool = PgPoolOptions::new()
        .max_connections(8)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&database_url)
        .await?;
    sqlx::migrate!("./migrations").run(&pool).await?; // refuse to serve if migrations fail

    let app = Router::new()
        .route("/healthz", get(health::healthz))
        .with_state(pool);
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    info!(%bind, "pulse-api listening");
    axum::serve(listener, app).await?;
    Ok(())
}
