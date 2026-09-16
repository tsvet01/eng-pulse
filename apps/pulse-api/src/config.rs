use std::collections::HashMap;

#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub bind_addr: String,
    pub supabase_jwks_url: String,
    pub supabase_issuer: String,
    pub supabase_audience: String,
    pub pipeline_service_token: String,
    pub admin_email: Option<String>,
}

impl Config {
    pub fn from_env() -> Result<Self, String> {
        let vars: HashMap<String, String> = std::env::vars().collect();
        Self::from_map(&vars)
    }

    pub fn from_map(v: &HashMap<String, String>) -> Result<Self, String> {
        let req = |k: &str| {
            v.get(k)
                .cloned()
                .filter(|s| !s.is_empty())
                .ok_or(format!("{k} is required"))
        };
        Ok(Self {
            database_url: req("DATABASE_URL")?,
            bind_addr: v
                .get("BIND_ADDR")
                .cloned()
                .unwrap_or_else(|| "0.0.0.0:8080".into()),
            supabase_jwks_url: req("SUPABASE_JWKS_URL")?,
            supabase_issuer: req("SUPABASE_ISSUER")?,
            supabase_audience: v
                .get("SUPABASE_AUDIENCE")
                .cloned()
                .unwrap_or_else(|| "authenticated".into()),
            pipeline_service_token: req("PIPELINE_SERVICE_TOKEN")?,
            admin_email: v.get("ADMIN_EMAIL").cloned().map(|e| e.to_lowercase()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> HashMap<String, String> {
        [
            ("DATABASE_URL", "postgres://x"),
            (
                "SUPABASE_JWKS_URL",
                "https://p.supabase.co/auth/v1/.well-known/jwks.json",
            ),
            ("SUPABASE_ISSUER", "https://p.supabase.co/auth/v1"),
            ("PIPELINE_SERVICE_TOKEN", "t"),
        ]
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
    }

    #[test]
    fn defaults_and_required() {
        let c = Config::from_map(&base()).unwrap();
        assert_eq!(c.bind_addr, "0.0.0.0:8080");
        assert_eq!(c.supabase_audience, "authenticated");
        assert!(c.admin_email.is_none());
        let mut m = base();
        m.remove("PIPELINE_SERVICE_TOKEN");
        assert_eq!(
            Config::from_map(&m).unwrap_err(),
            "PIPELINE_SERVICE_TOKEN is required"
        );
    }

    #[test]
    fn admin_email_lowercased() {
        let mut m = base();
        m.insert("ADMIN_EMAIL".into(), "Anton@Example.com".into());
        assert_eq!(
            Config::from_map(&m).unwrap().admin_email.as_deref(),
            Some("anton@example.com")
        );
    }
}
