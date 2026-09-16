pub mod admin;
pub mod briefs;
pub mod devices;
pub mod feeds;
pub mod internal;
pub mod users;

use crate::{health, state::AppState};
use axum::{routing::get, Router};
use tower_http::trace::TraceLayer;

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(health::healthz))
        .merge(users::routes())
        .merge(admin::routes())
        .merge(feeds::routes())
        .merge(briefs::routes())
        .merge(devices::routes())
        .merge(internal::routes())
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
