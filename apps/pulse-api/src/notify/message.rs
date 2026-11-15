use super::Message;
use crate::db::briefs::BriefRow;

const BODY_MAX: usize = 178;

pub fn build(row: &BriefRow, feed_slug: &str) -> Message {
    let body = match row.payload.get("key_idea").and_then(|v| v.as_str()) {
        Some(s) if !s.trim().is_empty() => cut(s.trim()),
        _ => row.article_title.clone(),
    };
    Message {
        title: row.article_title.clone(),
        body,
        feed_slug: feed_slug.to_string(),
        date: row.date,
    }
}

fn cut(s: &str) -> String {
    if s.chars().count() <= BODY_MAX {
        return s.to_string();
    }
    let head: String = s.chars().take(BODY_MAX - 1).collect();
    let fits = s.chars().nth(BODY_MAX - 1).is_some_and(char::is_whitespace);
    let head = match head.rfind(char::is_whitespace) {
        Some(i) if !fits => &head[..i],
        _ => &head,
    };
    format!("{}…", head.trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use serde_json::json;
    use uuid::Uuid;

    fn row(payload: serde_json::Value) -> BriefRow {
        BriefRow {
            feed_id: Uuid::nil(),
            date: NaiveDate::from_ymd_opt(2026, 11, 14).unwrap(),
            format: "insight-brief-v3".into(),
            payload,
            article_url: "https://example.com/a".into(),
            article_title: "Title".into(),
            model: None,
            eval_score: None,
        }
    }

    #[test]
    fn title_is_article_title() {
        let m = build(&row(json!({"key_idea": "k"})), "engineering");
        assert_eq!(m.title, "Title");
        assert_eq!(m.feed_slug, "engineering");
    }

    #[test]
    fn body_is_key_idea_cut_to_178_chars_on_a_word() {
        let idea = "word ".repeat(60);
        let m = build(&row(json!({ "key_idea": idea })), "engineering");
        assert!(m.body.chars().count() <= 178);
        assert!(m.body.ends_with("word…"));
    }

    #[test]
    fn missing_key_idea_falls_back_to_title() {
        let m = build(&row(json!({})), "engineering");
        assert_eq!(m.body, "Title");
    }

    #[test]
    fn short_key_idea_is_unchanged() {
        let m = build(&row(json!({"key_idea": "Short idea."})), "engineering");
        assert_eq!(m.body, "Short idea.");
    }
}
