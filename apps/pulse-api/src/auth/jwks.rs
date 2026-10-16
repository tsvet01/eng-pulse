use crate::{auth::claims::Claims, error::ApiError};
use jsonwebtoken::{decode, decode_header, jwk::JwkSet, Algorithm, DecodingKey, Validation};
use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::RwLock;

pub struct JwksCache {
    url: String,
    http: reqwest::Client,
    keys: RwLock<HashMap<String, (DecodingKey, Algorithm)>>,
    last_fetch: RwLock<Option<Instant>>,
}

/// Floor between key fetches, so an unknown kid cannot drive traffic at the issuer.
const MIN_REFRESH: Duration = Duration::from_secs(60);

impl JwksCache {
    pub fn new(url: String, http: reqwest::Client) -> Self {
        Self {
            url,
            http,
            keys: RwLock::new(HashMap::new()),
            last_fetch: RwLock::new(None),
        }
    }

    async fn refresh(&self) -> Result<(), ApiError> {
        let mut last = self.last_fetch.write().await;
        if last.map(|t| t.elapsed() < MIN_REFRESH).unwrap_or(false) {
            return Ok(());
        }
        // Stamp the attempt, not the success, so a failing issuer is retried at most once
        // per MIN_REFRESH instead of on every request.
        *last = Some(Instant::now());
        let set: JwkSet = self
            .http
            .get(&self.url)
            .send()
            .await
            .and_then(|r| r.error_for_status())
            .map_err(|e| ApiError::Internal(format!("jwks fetch: {e}")))?
            .json()
            .await
            .map_err(|e| ApiError::Internal(format!("jwks parse: {e}")))?;
        let mut keys = HashMap::new();
        for jwk in set.keys {
            let Some(kid) = jwk.common.key_id.clone() else {
                continue;
            };
            let alg = match jwk.common.key_algorithm {
                Some(jsonwebtoken::jwk::KeyAlgorithm::ES256) => Algorithm::ES256,
                Some(jsonwebtoken::jwk::KeyAlgorithm::RS256) => Algorithm::RS256,
                _ => continue,
            };
            if let Ok(key) = DecodingKey::from_jwk(&jwk) {
                keys.insert(kid, (key, alg));
            }
        }
        *self.keys.write().await = keys;
        Ok(())
    }

    async fn key_for(&self, kid: &str) -> Result<(DecodingKey, Algorithm), ApiError> {
        if let Some(k) = self.keys.read().await.get(kid) {
            return Ok(k.clone());
        }
        self.refresh().await?;
        self.keys
            .read()
            .await
            .get(kid)
            .cloned()
            .ok_or(ApiError::Unauthorized("unknown key id"))
    }

    pub async fn verify(
        &self,
        token: &str,
        issuer: &str,
        audience: &str,
    ) -> Result<Claims, ApiError> {
        let header = decode_header(token).map_err(|_| ApiError::Unauthorized("malformed token"))?;
        let kid = header
            .kid
            .ok_or(ApiError::Unauthorized("token has no kid"))?;
        let (key, alg) = self.key_for(&kid).await?;
        let mut v = Validation::new(alg);
        v.set_issuer(&[issuer]);
        v.set_audience(&[audience]);
        // Required, not just checked-if-present: a token omitting aud/iss must not pass.
        v.set_required_spec_claims(&["exp", "aud", "iss"]);
        v.validate_exp = true;
        v.leeway = 0; // expiry is exact; clients refresh rather than lean on skew
        decode::<Claims>(token, &key, &v)
            .map(|d| d.claims)
            .map_err(|_| ApiError::Unauthorized("invalid token"))
    }
}

pub type SharedJwks = Arc<JwksCache>;
