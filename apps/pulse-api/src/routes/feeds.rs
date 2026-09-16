use crate::{auth::extractors::AuthUser, db::feeds, error::ApiError, feedcheck, state::AppState};
use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v1/feeds", get(list).post(create))
        .route("/v1/feeds/{id}/membership", post(join).delete(leave))
        .route("/v1/feeds/{id}/topics", post(add_topic))
        .route(
            "/v1/feeds/{id}/topics/{topic}",
            axum::routing::delete(remove_topic),
        )
        .route(
            "/v1/feeds/{id}/sources",
            post(add_source).delete(remove_source),
        )
}

async fn list(State(s): State<AppState>, user: AuthUser) -> Result<Json<Vec<Value>>, ApiError> {
    let mut out = Vec::new();
    for f in feeds::list_for_user(&s.pool, user.id).await? {
        out.push(json!({
            "id": f.id, "slug": f.slug, "name": f.name, "description": f.description, "is_active": f.is_active,
            "member": f.role.is_some(), "role": f.role,
            "topics": feeds::topics(&s.pool, f.id).await?, "sources": feeds::sources(&s.pool, f.id).await?,
        }));
    }
    Ok(Json(out))
}

#[derive(Deserialize)]
struct NewFeed {
    slug: String,
    name: String,
    description: Option<String>,
}

fn valid_slug(s: &str) -> bool {
    (1..=40).contains(&s.len())
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

async fn create(
    State(s): State<AppState>,
    user: AuthUser,
    Json(b): Json<NewFeed>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    if !valid_slug(&b.slug) {
        return Err(ApiError::BadRequest(
            "slug: 1-40 chars of a-z, 0-9, -".into(),
        ));
    }
    if b.name.trim().is_empty() {
        return Err(ApiError::BadRequest("name is required".into()));
    }
    let id = feeds::create(
        &s.pool,
        user.id,
        &b.slug,
        b.name.trim(),
        b.description.as_deref(),
    )
    .await
    .map_err(|e| match e {
        sqlx::Error::Database(ref d) if d.is_unique_violation() => {
            ApiError::Conflict("slug already exists")
        }
        other => ApiError::Db(other),
    })?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"id": id, "slug": b.slug, "name": b.name.trim(), "role": "owner"})),
    ))
}

#[derive(Deserialize, Default)]
struct Join {
    notify_email: Option<bool>,
    notify_push: Option<bool>,
}

async fn join(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    body: Option<Json<Join>>,
) -> Result<StatusCode, ApiError> {
    if !feeds::exists(&s.pool, id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    let j = body.map(|b| b.0).unwrap_or_default();
    feeds::upsert_membership(&s.pool, user.id, id, j.notify_email, j.notify_push).await?;
    Ok(StatusCode::OK)
}

async fn leave(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    feeds::delete_membership(&s.pool, user.id, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn require_member(s: &AppState, user: &AuthUser, feed_id: Uuid) -> Result<(), ApiError> {
    if !feeds::exists(&s.pool, feed_id).await? {
        return Err(ApiError::NotFound("feed"));
    }
    if feeds::is_member(&s.pool, user.id, feed_id).await? {
        Ok(())
    } else {
        Err(ApiError::Forbidden)
    }
}

#[derive(Deserialize)]
struct Topic {
    topic: String,
}

async fn add_topic(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<Topic>,
) -> Result<StatusCode, ApiError> {
    require_member(&s, &user, id).await?;
    let topic = b.topic.trim().to_lowercase();
    if topic.is_empty() || topic.len() > 60 {
        return Err(ApiError::BadRequest("topic: 1-60 chars".into()));
    }
    feeds::add_topic(&s.pool, id, &topic, user.id).await?;
    Ok(StatusCode::CREATED)
}

async fn remove_topic(
    State(s): State<AppState>,
    user: AuthUser,
    Path((id, topic)): Path<(Uuid, String)>,
) -> Result<StatusCode, ApiError> {
    require_member(&s, &user, id).await?;
    feeds::remove_topic(&s.pool, id, &topic.to_lowercase()).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SourceBody {
    url: String,
}

async fn add_source(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(b): Json<SourceBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_member(&s, &user, id).await?;
    // No redirects: a 3xx could repoint the fetch at an internal address post-check.
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let kind = feedcheck::validate_feed_url(&http, b.url.trim())
        .await
        .map_err(ApiError::BadRequest)?;
    feeds::add_source(
        &s.pool,
        id,
        b.url.trim(),
        feedcheck::kind_str(kind),
        user.id,
    )
    .await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({"url": b.url.trim(), "kind": feedcheck::kind_str(kind)})),
    ))
}

#[derive(Deserialize)]
struct SourceQuery {
    url: String,
}

async fn remove_source(
    State(s): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Query(q): Query<SourceQuery>,
) -> Result<StatusCode, ApiError> {
    require_member(&s, &user, id).await?;
    feeds::remove_source(&s.pool, id, &q.url).await?;
    Ok(StatusCode::NO_CONTENT)
}
