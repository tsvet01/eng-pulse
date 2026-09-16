use serde::Deserialize;
use sqlx::PgPool;

#[derive(Debug, Deserialize)]
pub struct SourceEntry {
    pub name: String,
    pub r#type: String,
    pub url: String,
}

#[derive(Debug, Default)]
pub struct Summary {
    pub sources_active: usize,
}

/// `pulse-api seed --sources <url-or-path> --invite <CODE> [--invite-uses N]`
pub async fn run(pool: &PgPool, args: &[String]) -> Result<(), String> {
    let get = |flag: &str| {
        args.iter()
            .position(|a| a == flag)
            .and_then(|i| args.get(i + 1))
            .cloned()
    };
    let sources = get("--sources").ok_or("--sources <url-or-path> is required")?;
    let invite = get("--invite").ok_or("--invite <CODE> is required")?;
    let uses: i32 = get("--invite-uses")
        .map(|v| {
            v.parse()
                .map_err(|_| "--invite-uses must be a number".to_string())
        })
        .transpose()?
        .unwrap_or(5);
    let raw = if sources.starts_with("http") {
        reqwest::get(&sources)
            .await
            .and_then(|r| r.error_for_status())
            .map_err(|e| e.to_string())?
            .text()
            .await
            .map_err(|e| e.to_string())?
    } else {
        std::fs::read_to_string(&sources).map_err(|e| e.to_string())?
    };
    let entries: Vec<SourceEntry> =
        serde_json::from_str(&raw).map_err(|e| format!("sources json: {e}"))?;
    let s = apply(pool, &entries, &invite, uses).await?;
    println!(
        "seeded engineering: {} active sources; invite {invite} ({uses} uses)",
        s.sources_active
    );
    Ok(())
}

/// Upserts the `engineering` feed, replaces its active sources, and upserts the invite. Idempotent.
pub async fn apply(
    pool: &PgPool,
    sources: &[SourceEntry],
    invite: &str,
    uses: i32,
) -> Result<Summary, String> {
    let mut tx = pool.begin().await.map_err(|e| e.to_string())?;
    let feed_id: uuid::Uuid = sqlx::query_scalar(
        "insert into feeds (slug, name, description) values ('engineering', 'Engineering', 'Systems, infrastructure, AI tooling') on conflict (slug) do update set name = excluded.name returning id",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|e| e.to_string())?;
    sqlx::query("update feed_sources set is_active = false where feed_id = $1")
        .bind(feed_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| e.to_string())?;
    for s in sources {
        let kind = match s.r#type.as_str() {
            "atom" => "atom",
            "hackernews" => "hackernews",
            _ => "rss",
        };
        sqlx::query("insert into feed_sources (feed_id, url, kind) values ($1, $2, $3) on conflict (feed_id, url) do update set kind = excluded.kind, is_active = true")
            .bind(feed_id).bind(&s.url).bind(kind).execute(&mut *tx).await.map_err(|e| e.to_string())?;
    }
    sqlx::query(
        "insert into invites (code, max_uses) values ($1, $2) on conflict (code) do update set max_uses = excluded.max_uses",
    )
    .bind(invite)
    .bind(uses)
    .execute(&mut *tx)
    .await
    .map_err(|e| e.to_string())?;
    tx.commit().await.map_err(|e| e.to_string())?;
    Ok(Summary {
        sources_active: sources.len(),
    })
}
