//! Silent, atomic import of already-published engineering briefs.
use crate::db::briefs::BriefRow;
use chrono::{Days, NaiveDate, Utc};
use pulse_core::Brief;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use std::{collections::BTreeMap, time::Duration};

pub const GCS_ROOT: &str = "https://storage.googleapis.com/tsvet01-agent-brain/";
const MANIFEST_LIMIT: usize = 4 * 1024 * 1024;
const ARTIFACT_LIMIT: usize = 2 * 1024 * 1024;

pub struct PublicArchive {
    base: reqwest::Url,
    http: reqwest::Client,
}

#[derive(Debug, Deserialize, PartialEq)]
struct ManifestEntry {
    date: String,
    url: String,
    title: String,
    original_url: Option<String>,
    model: Option<String>,
    eval_score: Option<f64>,
    format: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ImportReport {
    pub window_start: NaiveDate,
    pub window_end: NaiveDate,
    pub expected_dates: Vec<NaiveDate>,
    pub missing_dates: Vec<NaiveDate>,
    pub inserted: usize,
    pub unchanged: usize,
    pub verified: usize,
}

impl PublicArchive {
    pub fn new(base: reqwest::Url) -> Result<Self, String> {
        if !matches!(base.scheme(), "http" | "https")
            || base.host_str().is_none()
            || !base.username().is_empty()
            || base.password().is_some()
            || base.query().is_some()
            || base.fragment().is_some()
            || !base.path().ends_with('/')
        {
            return Err("invalid archive root".into());
        }
        let http = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(15))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "could not initialize archive HTTP client")?;
        Ok(Self { base, http })
    }

    async fn bytes(&self, relative: &str, limit: usize) -> Result<Vec<u8>, String> {
        let url = self
            .base
            .join(relative)
            .map_err(|_| "invalid archive path")?;
        let mut response = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|_| "archive request failed")?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(format!(
                "archive returned HTTP {} for {relative}",
                response.status().as_u16()
            ));
        }
        if response
            .content_length()
            .is_some_and(|length| length > limit as u64)
        {
            return Err(format!("archive object exceeds size limit: {relative}"));
        }
        let mut data = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| "archive body read failed")?
        {
            if data.len() + chunk.len() > limit {
                return Err(format!("archive object exceeds size limit: {relative}"));
            }
            data.extend_from_slice(&chunk);
        }
        Ok(data)
    }

    async fn manifest(
        &self,
        start: NaiveDate,
        end: NaiveDate,
    ) -> Result<BTreeMap<NaiveDate, ManifestEntry>, String> {
        let data = self.bytes("manifest.json", MANIFEST_LIMIT).await?;
        let entries: Vec<ManifestEntry> =
            serde_json::from_slice(&data).map_err(|_| "invalid archive manifest")?;
        let mut selected = BTreeMap::new();
        for entry in entries {
            if entry.format.as_deref() != Some("insight-brief-v3") {
                continue;
            }
            let date = NaiveDate::parse_from_str(&entry.date, "%Y-%m-%d")
                .map_err(|_| "invalid V3 manifest date")?;
            if date < start || date > end {
                continue;
            }
            let expected = self
                .base
                .join(&format!("summaries/v3/{date}.json"))
                .map_err(|_| "invalid artifact path")?;
            if entry.date != date.to_string() || entry.url != expected.as_str() {
                return Err(format!("unexpected artifact URL for {date}"));
            }
            let article = entry
                .original_url
                .as_deref()
                .and_then(|url| reqwest::Url::parse(url).ok());
            if entry.title.trim().is_empty()
                || !article.is_some_and(|url| {
                    matches!(url.scheme(), "http" | "https")
                        && url.host_str().is_some()
                        && url.username().is_empty()
                        && url.password().is_none()
                })
            {
                return Err(format!("missing or invalid article metadata for {date}"));
            }
            if selected.insert(date, entry).is_some() {
                return Err(format!("duplicate V3 manifest date: {date}"));
            }
        }
        if selected.is_empty() {
            return Err("no published V3 briefs in the requested window".into());
        }
        Ok(selected)
    }

    async fn briefs(&self, start: NaiveDate, end: NaiveDate) -> Result<Vec<Brief>, String> {
        let entries = self.manifest(start, end).await?;
        let mut briefs = Vec::with_capacity(entries.len());
        for (date, entry) in &entries {
            let bytes = self
                .bytes(&format!("summaries/v3/{date}.json"), ARTIFACT_LIMIT)
                .await?;
            let payload = serde_json::from_slice(&bytes)
                .map_err(|_| format!("invalid artifact JSON for {date}"))?;
            pulse_core::validate_payload(&payload)
                .map_err(|_| format!("invalid V3 payload for {date}"))?;
            briefs.push(Brief {
                feed_slug: "engineering".into(),
                date: date.to_string(),
                format: "insight-brief-v3".into(),
                payload,
                article_url: entry
                    .original_url
                    .clone()
                    .ok_or("missing original article URL")?,
                article_title: entry.title.clone(),
                model: entry.model.clone(),
                eval_score: entry.eval_score,
            });
        }
        // A concurrent publication must not mix two manifest snapshots.
        if self.manifest(start, end).await? != entries {
            return Err("archive manifest changed during import; retry".into());
        }
        Ok(briefs)
    }
}

pub async fn import_window(
    pool: &PgPool,
    source: &PublicArchive,
    end: NaiveDate,
) -> Result<ImportReport, String> {
    tokio::time::timeout(Duration::from_secs(180), import_inner(pool, source, end))
        .await
        .map_err(|_| "history import exceeded its three-minute limit".to_string())?
}

async fn import_inner(
    pool: &PgPool,
    source: &PublicArchive,
    end: NaiveDate,
) -> Result<ImportReport, String> {
    let start = end
        .checked_sub_days(Days::new(29))
        .ok_or("invalid history window")?;
    let ready: bool = sqlx::query_scalar(
        "select exists(select 1 from feeds where slug='engineering' and is_active)",
    )
    .fetch_one(pool)
    .await
    .map_err(|_| "could not check engineering feed")?;
    if !ready {
        return Err("active engineering feed is required".into());
    }
    let briefs = source.briefs(start, end).await?;
    let mut tx = pool
        .begin()
        .await
        .map_err(|_| "could not begin import transaction")?;
    sqlx::query("set local lock_timeout = '5s'")
        .execute(&mut *tx)
        .await
        .map_err(|_| "could not set import lock limit")?;
    sqlx::query("set local statement_timeout = '15s'")
        .execute(&mut *tx)
        .await
        .map_err(|_| "could not set import query limit")?;
    let feed_id: uuid::Uuid =
        sqlx::query_scalar("select id from feeds where slug='engineering' and is_active for share")
            .fetch_optional(&mut *tx)
            .await
            .map_err(|_| "could not lock engineering feed")?
            .ok_or("active engineering feed is required")?;
    let mut report = ImportReport {
        window_start: start,
        window_end: end,
        expected_dates: Vec::new(),
        missing_dates: Vec::new(),
        inserted: 0,
        unchanged: 0,
        verified: 0,
    };
    for brief in &briefs {
        let date =
            NaiveDate::parse_from_str(&brief.date, "%Y-%m-%d").map_err(|_| "invalid brief date")?;
        // Import never replaces a live write or runs notification/LLM paths.
        let result = sqlx::query("insert into briefs(feed_id,date,format,payload,article_url,article_title,model,eval_score) values($1,$2,$3,$4,$5,$6,$7,$8) on conflict(feed_id,date) do nothing")
            .bind(feed_id).bind(date).bind(&brief.format).bind(&brief.payload).bind(&brief.article_url)
            .bind(&brief.article_title).bind(&brief.model).bind(brief.eval_score)
            .execute(&mut *tx).await.map_err(|_| format!("could not import brief for {date}"))?;
        let stored: BriefRow = sqlx::query_as("select feed_id,date,format,payload,article_url,article_title,model,eval_score from briefs where feed_id=$1 and date=$2 for share")
            .bind(feed_id).bind(date).fetch_one(&mut *tx).await.map_err(|_| format!("could not verify brief for {date}"))?;
        if stored.format != brief.format
            || stored.payload != brief.payload
            || stored.article_url != brief.article_url
            || stored.article_title != brief.article_title
            || stored.model != brief.model
            || stored.eval_score != brief.eval_score
        {
            return Err(format!(
                "stored brief differs from archive for {date}; no changes committed"
            ));
        }
        report.inserted += result.rows_affected() as usize;
        report.unchanged += usize::from(result.rows_affected() == 0);
        report.verified += 1;
        report.expected_dates.push(date);
    }
    for offset in 0..30 {
        let date = start
            .checked_add_days(Days::new(offset))
            .ok_or("invalid history date")?;
        if !report.expected_dates.contains(&date) {
            report.missing_dates.push(date);
        }
    }
    tx.commit()
        .await
        .map_err(|_| "could not commit history import; verify before retrying")?;
    Ok(report)
}

pub async fn run(pool: &PgPool, args: &[String]) -> Result<(), String> {
    if !args.is_empty() {
        return Err("import-history takes no arguments; imports the latest 30 UTC dates".into());
    }
    let source = PublicArchive::new(
        GCS_ROOT
            .parse()
            .map_err(|_| "invalid public archive root")?,
    )?;
    let report = import_window(pool, &source, Utc::now().date_naive()).await?;
    println!(
        "{}",
        serde_json::to_string(&report).map_err(|_| "could not encode import report")?
    );
    Ok(())
}
