use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub iss: String,
    pub exp: usize,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub user_metadata: Option<UserMetadata>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct UserMetadata {
    #[serde(default)]
    pub email_verified: bool,
}

impl Claims {
    pub fn email_verified(&self) -> bool {
        self.user_metadata
            .as_ref()
            .map(|m| m.email_verified)
            .unwrap_or(false)
    }

    pub fn email_lower(&self) -> Option<String> {
        self.email.as_ref().map(|e| e.trim().to_lowercase())
    }
}
