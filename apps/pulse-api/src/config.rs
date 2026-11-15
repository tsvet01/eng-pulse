use crate::notify::apns::ApnsConfig;
use base64::{engine::general_purpose::STANDARD, Engine};
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
    pub reconcile_history_enabled: bool,
    pub notify_push_enabled: bool,
    pub apns: Option<ApnsConfig>,
}

impl ApnsConfig {
    pub(crate) fn from_lookup(lookup: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let required = |key: &str| {
            lookup(key)
                .filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{key} is required"))
        };
        let key = required("APNS_KEY_BASE64")?;
        let key_id = required("APNS_KEY_ID")?;
        let team_id = required("APNS_TEAM_ID")?;
        let key_pem = STANDARD
            .decode(key.trim())
            .ok()
            .and_then(|b| String::from_utf8(b).ok())
            .ok_or("APNS_KEY_BASE64 is invalid")?;
        let or = |k: &str, d: &str| {
            lookup(k)
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| d.into())
        };
        Ok(Self {
            key_pem,
            key_id,
            team_id,
            topic: or("APNS_TOPIC", "org.tsvetkov.eng-pulse"),
            production_url: or("APNS_PRODUCTION_URL", "https://api.push.apple.com"),
            sandbox_url: or("APNS_SANDBOX_URL", "https://api.sandbox.push.apple.com"),
        })
    }
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
        let notify_push_enabled = match v.get("NOTIFY_PUSH_ENABLED").map(String::as_str) {
            None | Some("false") => false,
            Some("true") => true,
            _ => return Err("NOTIFY_PUSH_ENABLED must be true or false".into()),
        };
        let apns = if notify_push_enabled {
            Some(ApnsConfig::from_lookup(|k| v.get(k).cloned())?)
        } else {
            None
        };
        Ok(Self {
            apns,
            notify_push_enabled,
            reconcile_history_enabled: match v.get("RECONCILE_HISTORY_ENABLED").map(String::as_str)
            {
                None | Some("false") => false,
                Some("true") => true,
                _ => return Err("RECONCILE_HISTORY_ENABLED must be true or false".into()),
            },
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
            // An empty value must not make an email-less token an admin.
            admin_email: v
                .get("ADMIN_EMAIL")
                .map(|e| e.trim().to_lowercase())
                .filter(|e| !e.is_empty()),
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
    fn admin_email_empty_is_none() {
        for value in ["", "   "] {
            let mut m = base();
            m.insert("ADMIN_EMAIL".into(), value.into());
            assert!(
                Config::from_map(&m).unwrap().admin_email.is_none(),
                "{value:?}"
            );
        }
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

    fn push_on() -> HashMap<String, String> {
        let mut m = base();
        for (k, v) in [
            ("NOTIFY_PUSH_ENABLED", "true"),
            ("APNS_KEY_BASE64", "U0VDUkVULUtFWQ=="),
            ("APNS_KEY_ID", "KEYID"),
            ("APNS_TEAM_ID", "TEAMID"),
        ] {
            m.insert(k.into(), v.into());
        }
        m
    }

    #[test]
    fn push_off_needs_no_apns_settings() {
        assert!(Config::from_map(&base()).unwrap().apns.is_none());
    }

    #[test]
    fn push_on_names_the_first_missing_setting() {
        for k in ["APNS_KEY_BASE64", "APNS_KEY_ID", "APNS_TEAM_ID"] {
            let mut m = push_on();
            m.remove(k);
            assert_eq!(
                Config::from_map(&m).unwrap_err(),
                format!("{k} is required")
            );
        }
        let mut m = push_on();
        m.remove("APNS_KEY_ID");
        m.remove("APNS_TEAM_ID");
        assert_eq!(Config::from_map(&m).unwrap_err(), "APNS_KEY_ID is required");
    }

    #[test]
    fn push_on_applies_defaults_and_decodes_key() {
        let a = Config::from_map(&push_on()).unwrap().apns.unwrap();
        assert_eq!(a.key_pem, "SECRET-KEY");
        assert_eq!(a.topic, "org.tsvetkov.eng-pulse");
        assert_eq!(a.production_url, "https://api.push.apple.com");
        assert_eq!(a.sandbox_url, "https://api.sandbox.push.apple.com");
    }

    #[test]
    fn invalid_key_encoding_is_rejected() {
        for bad in ["not base64!", "/w=="] {
            let mut m = push_on();
            m.insert("APNS_KEY_BASE64".into(), bad.into());
            assert_eq!(
                Config::from_map(&m).unwrap_err(),
                "APNS_KEY_BASE64 is invalid"
            );
        }
    }

    #[test]
    fn debug_output_hides_the_key() {
        let c = Config::from_map(&push_on()).unwrap();
        let out = format!("{c:?}");
        assert!(!out.contains("SECRET-KEY") && !out.contains("U0VDUkVULUtFWQ"));
    }
}
