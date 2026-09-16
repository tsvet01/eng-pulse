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
    pub fn email_lower(&self) -> Option<String> {
        self.email.as_ref().map(|e| e.trim().to_lowercase())
    }
}
