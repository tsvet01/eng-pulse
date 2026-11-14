use super::{Deliver, Message, SendError};
use jsonwebtoken::{Algorithm, EncodingKey, Header};
use serde_json::json;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;

const JWT_TTL: Duration = Duration::from_secs(50 * 60);

pub fn is_apns_token(s: &str) -> bool {
    (64..=200).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_hexdigit())
}

pub struct ApnsConfig {
    pub key_pem: String,
    pub key_id: String,
    pub team_id: String,
    pub topic: String,
    pub production_url: String,
    pub sandbox_url: String,
}

pub struct Apns {
    cfg: ApnsConfig,
    key: EncodingKey,
    http: reqwest::Client,
    jwt: Mutex<Option<(String, Instant)>>,
}

impl Apns {
    pub fn new(cfg: ApnsConfig) -> Result<Self, String> {
        let key = EncodingKey::from_ec_pem(cfg.key_pem.as_bytes())
            .map_err(|_| "APNs key is not a valid P-256 PEM".to_string())?;
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
            .map_err(|e| format!("APNs client: {e}"))?;
        Ok(Self {
            cfg,
            key,
            http,
            jwt: Mutex::new(None),
        })
    }

    async fn bearer(&self) -> Result<String, SendError> {
        let mut g = self.jwt.lock().await;
        if let Some((t, at)) = g.as_ref() {
            if at.elapsed() < JWT_TTL {
                return Ok(t.clone());
            }
        }
        let mut h = Header::new(Algorithm::ES256);
        h.kid = Some(self.cfg.key_id.clone());
        let claims = json!({"iss": self.cfg.team_id, "iat": chrono::Utc::now().timestamp()});
        let t = jsonwebtoken::encode(&h, &claims, &self.key)
            .map_err(|_| SendError::Permanent("APNs JWT signing failed".into()))?;
        *g = Some((t.clone(), Instant::now()));
        Ok(t)
    }
}

impl Deliver for Apns {
    async fn push(&self, token: &str, sandbox: bool, m: &Message) -> Result<(), SendError> {
        if !is_apns_token(token) {
            return Err(SendError::InvalidToken);
        }
        let base = if sandbox {
            &self.cfg.sandbox_url
        } else {
            &self.cfg.production_url
        };
        let body = json!({
            "aps": {"alert": {"title": m.title, "body": m.body}, "sound": "default"},
            "feed": m.feed_slug,
            "date": m.date.to_string(),
        });
        let jwt = self.bearer().await?;
        let resp = self
            .http
            .post(format!("{base}/3/device/{token}"))
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", &self.cfg.topic)
            .header("apns-push-type", "alert")
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                let kind = if e.is_timeout() {
                    "timeout"
                } else {
                    "connection error"
                };
                SendError::Transient(format!("APNs request failed: {kind}"))
            })?;

        let status = resp.status().as_u16();
        if status == 200 {
            return Ok(());
        }
        let reason = resp
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|v| v["reason"].as_str().map(str::to_owned));
        let r = reason.as_deref();
        let msg = format!("APNs {status} {}", r.unwrap_or("no reason"));
        match (status, r) {
            (_, Some("Unregistered")) | (410, _) => Err(SendError::InvalidToken),
            (400, Some("BadDeviceToken" | "DeviceTokenNotForTopic")) => {
                Err(SendError::InvalidToken)
            }
            (403, Some("ExpiredProviderToken")) => {
                *self.jwt.lock().await = None;
                Err(SendError::Transient(msg))
            }
            (429 | 500..=599, _) => Err(SendError::Transient(msg)),
            _ => Err(SendError::Permanent(msg)),
        }
    }
}
