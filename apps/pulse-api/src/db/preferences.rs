use chrono::{DateTime, Utc};
use pulse_core::preferences::PreferenceChoices;
use sqlx::{types::Json, PgPool};
use uuid::Uuid;

#[derive(Default, sqlx::FromRow)]
pub struct PreferencesRow {
    pub preferences: Json<PreferenceChoices>,
    pub revision: i64,
    pub learned_reset_at: Option<DateTime<Utc>>,
}

pub async fn get(pool: &PgPool, user: Uuid) -> sqlx::Result<PreferencesRow> {
    Ok(sqlx::query_as(
        "select preferences, revision, learned_reset_at from user_preferences where user_id=$1",
    )
    .bind(user)
    .fetch_optional(pool)
    .await?
    .unwrap_or_default())
}

pub async fn put(
    pool: &PgPool,
    user: Uuid,
    choices: &PreferenceChoices,
    expected: i64,
    reset: bool,
) -> sqlx::Result<Option<PreferencesRow>> {
    sqlx::query_as(
        "insert into user_preferences (user_id,preferences,revision,learned_reset_at)
        select $1,$2,1,case when $4 then now() else null end
        where $3=0 or exists(select 1 from user_preferences where user_id=$1)
        on conflict(user_id) do update set preferences=excluded.preferences,
            revision=user_preferences.revision+1, updated_at=now(),
            learned_reset_at=case when $4 then now() else user_preferences.learned_reset_at end
        where user_preferences.revision=$3
        returning preferences,revision,learned_reset_at",
    )
    .bind(user)
    .bind(Json(choices))
    .bind(expected)
    .bind(reset)
    .fetch_optional(pool)
    .await
}
