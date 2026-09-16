use crate::{auth::extractors::ServiceToken, state::AppState};
use axum::{routing::get, Json, Router};

pub fn routes() -> Router<AppState> {
    Router::new().route("/internal/feeds", get(feeds))
}

async fn feeds(_: ServiceToken) -> Json<Vec<pulse_core::Feed>> {
    Json(Vec::new())
}
