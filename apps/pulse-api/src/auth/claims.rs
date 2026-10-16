use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Claims {
    pub sub: String,
    pub iss: String,
    pub exp: usize,
    #[serde(default)]
    pub email: Option<String>,
}

impl Claims {
    /// An empty or whitespace-only claim counts as no email at all.
    pub fn email_lower(&self) -> Option<String> {
        self.email
            .as_ref()
            .map(|e| e.trim().to_lowercase())
            .filter(|e| !e.is_empty())
    }
}
