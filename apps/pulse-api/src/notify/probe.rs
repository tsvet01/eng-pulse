//! Operator-only probe. It never starts the API, runs migrations or touches the daily outbox.
use super::{
    apns::{is_apns_token, Apns, ApnsConfig},
    Deliver, Message,
};
use sqlx::{postgres::PgPoolOptions, PgPool};
use uuid::Uuid;

const DB_ERROR: &str = "database check failed; do not retry a send with a new ID";
const USED: &str = "test ID already reserved; no send";
const NO_MATCH: &str = "no unique eligible admin sandbox device for the supplied receipt";

struct Target {
    user: Uuid,
    hash: String,
    email: String,
    issuer: String,
}

fn env(key: &str) -> Result<String, String> {
    std::env::var(key)
        .ok()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| format!("{key} is required"))
}

fn provider(lookup: impl Fn(&str) -> Option<String>) -> Result<Apns, String> {
    if lookup("NOTIFY_PUSH_ENABLED").as_deref() != Some("false") {
        return Err("daily push must explicitly be disabled".into());
    }
    let cfg = ApnsConfig::from_lookup(lookup)?;
    if cfg.sandbox_url != "https://api.sandbox.push.apple.com"
        || cfg.production_url != "https://api.push.apple.com"
        || cfg.topic != "org.tsvetkov.eng-pulse"
    {
        return Err("the probe requires Apple endpoints and the pilot topic".into());
    }
    Apns::new(cfg)
}

pub async fn run(args: &[String]) -> Result<(), String> {
    let [mode, id] = args else {
        return Err("usage: pilot-push-test check|send TEST_UUID".into());
    };
    let send = match mode.as_str() {
        "check" => false,
        "send" => true,
        _ => return Err("expected check or send".into()),
    };
    let id = Uuid::parse_str(id).map_err(|_| "invalid test ID")?;
    let target = Target {
        user: Uuid::parse_str(&env("PILOT_PUSH_TEST_USER_ID")?)
            .map_err(|_| "invalid account receipt")?,
        hash: env("PILOT_PUSH_TEST_TOKEN_SHA256")?,
        email: env("ADMIN_EMAIL")?,
        issuer: env("SUPABASE_ISSUER")?,
    };
    if target.hash.len() != 64
        || !target
            .hash
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        return Err("invalid fingerprint receipt".into());
    }
    let apns = provider(|k| std::env::var(k).ok())?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .acquire_timeout(std::time::Duration::from_secs(5))
        .connect(&env("DATABASE_URL")?)
        .await
        .map_err(|_| DB_ERROR)?;
    let report = perform(&pool, &apns, &target, id, send).await?;
    println!("{report}");
    Ok(())
}

async fn perform(
    pool: &PgPool,
    apns: &impl Deliver,
    t: &Target,
    id: Uuid,
    send: bool,
) -> Result<&'static str, &'static str> {
    // Keep eligibility rows locked through the one bounded provider call; sign-out and opt-out serialize with it.
    let mut tx = pool.begin().await.map_err(|_| DB_ERROR)?;
    let matches: Vec<String> = sqlx::query_scalar(
        "select d.token from device_tokens d
         join users u on u.id=d.user_id
         join identities i on i.user_id=u.id and i.issuer=$4
         join memberships m on m.user_id=u.id
         join feeds f on f.id=m.feed_id and f.slug='engineering'
         where u.id=$1 and u.email=$2::citext and u.is_admin and u.is_active
           and m.notify_push and f.is_active and d.is_active and d.platform='ios' and d.environment='sandbox'
           and encode(sha256(convert_to(d.token,'UTF8')), 'hex')=$3
         limit 2 for share of d,u,i,m,f")
        .bind(t.user).bind(&t.email).bind(&t.hash).bind(&t.issuer)
        .fetch_all(&mut *tx).await.map_err(|_| DB_ERROR)?;
    let [token] = matches.as_slice() else {
        return Err(NO_MATCH);
    };
    if !is_apns_token(token) {
        return Err(NO_MATCH);
    }

    if !send {
        let used: bool = sqlx::query_scalar(
            "select exists(select 1 from pilot_push_test_attempts where test_id=$1)",
        )
        .bind(id)
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| DB_ERROR)?;
        if used {
            return Err(USED);
        }
        return Ok("Eligible device and local provider configuration verified; nothing sent.");
    }

    // Commit independently before any network I/O. Even a crash or an ambiguous commit cannot cause a resend.
    let reserved = sqlx::query(
        "insert into pilot_push_test_attempts(test_id) values ($1) on conflict do nothing",
    )
    .bind(id)
    .execute(pool)
    .await
    .map_err(|_| DB_ERROR)?
    .rows_affected();
    if reserved != 1 {
        return Err(USED);
    }
    let message = Message {
        title: "Eng Pulse pilot test".into(),
        body: "Push notifications are working on this device.".into(),
        feed_slug: "pilot-test".into(),
        date: chrono::Utc::now().date_naive(),
    };
    let accepted = apns.push(token, true, &message).await.is_ok();
    sqlx::query("update pilot_push_test_attempts set outcome=$2 where test_id=$1")
        .bind(id)
        .bind(if accepted {
            "accepted"
        } else {
            "not_confirmed"
        })
        .execute(&mut *tx)
        .await
        .map_err(|_| DB_ERROR)?;
    tx.commit().await.map_err(|_| DB_ERROR)?;
    if accepted {
        Ok("Apple accepted one sandbox push; device receipt still needs confirmation.")
    } else {
        Err("Apple acceptance not confirmed; the test ID is spent. Do not retry.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notify::SendError;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Recorder {
        calls: AtomicUsize,
        accept: bool,
    }
    impl Deliver for Recorder {
        async fn push(&self, token: &str, sandbox: bool, m: &Message) -> Result<(), SendError> {
            assert!(sandbox && token == "a".repeat(64));
            assert_eq!(m.feed_slug, "pilot-test");
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.accept {
                Ok(())
            } else {
                Err(SendError::Transient("fixture".into()))
            }
        }
    }

    async fn fixture(pool: &PgPool) -> Target {
        let email = "admin@example.test".to_owned();
        let issuer = "test-issuer".to_owned();
        let user = Uuid::new_v4();
        let user_args = [
            "insert into users(id,email,is_admin) values($1,'admin@example.test',true)",
            "insert into identities(user_id,issuer,subject) values($1,'test-issuer','test-subject')",
            "insert into feeds(id,slug,name) values($1,'engineering','Engineering')",
            "insert into memberships(user_id,feed_id) values($1,$1)",
            "insert into device_tokens(user_id,platform,environment,token) values($1,'ios','sandbox',repeat('a',64)),($1,'ios','sandbox',repeat('b',64))",
        ];
        for stmt in user_args {
            sqlx::query(stmt).bind(user).execute(pool).await.unwrap();
        }
        // SHA-256 of the 64-character UTF-8 token string (not decoded bytes).
        let hash = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb".into();
        Target {
            user,
            hash,
            email,
            issuer,
        }
    }

    #[sqlx::test]
    async fn check_success_ambiguity_and_crash_share_a_permanent_reservation(pool: PgPool) {
        let t = fixture(&pool).await;
        for accept in [true, false] {
            let recorder = Recorder {
                calls: AtomicUsize::new(0),
                accept,
            };
            let id = Uuid::new_v4();
            assert!(perform(&pool, &recorder, &t, id, false).await.is_ok());
            assert_eq!(recorder.calls.load(Ordering::SeqCst), 0);
            // Two independent invocations use the same authorization.
            let (a, b) = tokio::join!(
                perform(&pool, &recorder, &t, id, true),
                perform(&pool, &recorder, &t, id, true)
            );
            assert!(a == Err(USED) || b == Err(USED));
            assert_eq!(a.is_ok() || b.is_ok(), accept);
            assert_eq!(recorder.calls.load(Ordering::SeqCst), 1);
            let outcome: String =
                sqlx::query_scalar("select outcome from pilot_push_test_attempts where test_id=$1")
                    .bind(id)
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            assert_eq!(outcome, if accept { "accepted" } else { "not_confirmed" });
            assert_eq!(perform(&pool, &recorder, &t, id, true).await, Err(USED));
            assert_eq!(recorder.calls.load(Ordering::SeqCst), 1);
        }
        let id = Uuid::new_v4();
        sqlx::query("insert into pilot_push_test_attempts(test_id) values($1)")
            .bind(id)
            .execute(&pool)
            .await
            .unwrap();
        let recorder = Recorder {
            calls: AtomicUsize::new(0),
            accept: true,
        };
        assert_eq!(perform(&pool, &recorder, &t, id, true).await, Err(USED));
        assert_eq!(recorder.calls.load(Ordering::SeqCst), 0);
    }

    #[sqlx::test]
    async fn refuses_ineligible_target_without_fallback_or_reservation(pool: PgPool) {
        let mut t = fixture(&pool).await;
        let recorder = Recorder {
            calls: AtomicUsize::new(0),
            accept: true,
        };
        let id = Uuid::new_v4();
        let original = t.user;
        t.user = Uuid::new_v4();
        assert_eq!(perform(&pool, &recorder, &t, id, true).await, Err(NO_MATCH));
        t.user = original;
        for (disable, enable) in [
            (
                "update memberships set notify_push=false",
                "update memberships set notify_push=true",
            ),
            (
                "update feeds set is_active=false",
                "update feeds set is_active=true",
            ),
            (
                "update users set is_active=false",
                "update users set is_active=true",
            ),
            (
                "update users set is_admin=false",
                "update users set is_admin=true",
            ),
            (
                "update users set email='other@example.test'",
                "update users set email='admin@example.test'",
            ),
            (
                "update identities set issuer='wrong'",
                "update identities set issuer='test-issuer'",
            ),
            (
                "update device_tokens set is_active=false where token=repeat('a',64)",
                "update device_tokens set is_active=true",
            ),
            (
                "update device_tokens set platform='android' where token=repeat('a',64)",
                "update device_tokens set platform='ios'",
            ),
            (
                "update device_tokens set environment='production' where token=repeat('a',64)",
                "update device_tokens set environment='sandbox'",
            ),
        ] {
            sqlx::query(disable).execute(&pool).await.unwrap();
            assert_eq!(perform(&pool, &recorder, &t, id, true).await, Err(NO_MATCH));
            sqlx::query(enable).execute(&pool).await.unwrap();
        }
        sqlx::query(
            "insert into identities(user_id,issuer,subject) values($1,'test-issuer','ambiguous')",
        )
        .bind(t.user)
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(perform(&pool, &recorder, &t, id, true).await, Err(NO_MATCH));
        assert_eq!(recorder.calls.load(Ordering::SeqCst), 0);
        let count: i64 = sqlx::query_scalar("select count(*) from pilot_push_test_attempts")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn explicit_disabled_flag_credentials_and_apple_urls_are_required() {
        use std::collections::HashMap;
        let mut vars = HashMap::new();
        let error =
            |v: &HashMap<&str, &str>| provider(|k| v.get(k).map(|s| s.to_string())).err().unwrap();
        assert!(error(&vars).contains("disabled"));
        vars.insert("NOTIFY_PUSH_ENABLED", "true");
        assert!(error(&vars).contains("disabled"));
        vars.insert("NOTIFY_PUSH_ENABLED", "false");
        assert!(error(&vars).contains("APNS_KEY_BASE64 is required"));
        vars.extend([
            ("APNS_KEY_BASE64", "dGVzdA=="),
            ("APNS_KEY_ID", "id"),
            ("APNS_TEAM_ID", "team"),
            ("APNS_SANDBOX_URL", "http://localhost:1"),
        ]);
        assert!(error(&vars).contains("Apple endpoints"));
    }
}
