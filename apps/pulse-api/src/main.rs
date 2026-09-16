mod auth;
mod config;
mod db;
mod error;
mod feedcheck;
mod health;
mod routes;
mod seed;
mod state;

use config::Config;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
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

    let cfg = Arc::new(Config::from_env()?);
    let pool = PgPoolOptions::new()
        .max_connections(8)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&cfg.database_url)
        .await?;
    sqlx::migrate!("./migrations").run(&pool).await?; // refuse to serve if migrations fail

    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("seed") {
        return seed::run(&pool, &args[1..]).await.map_err(Into::into);
    }

    let jwks = Arc::new(auth::jwks::JwksCache::new(
        cfg.supabase_jwks_url.clone(),
        reqwest::Client::new(),
    ));
    let state = state::AppState {
        pool,
        cfg: cfg.clone(),
        jwks,
    };
    let listener = tokio::net::TcpListener::bind(&cfg.bind_addr).await?;
    info!(bind = %cfg.bind_addr, "pulse-api listening");
    axum::serve(listener, routes::router(state)).await?;
    Ok(())
}
