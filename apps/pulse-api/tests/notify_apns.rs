mod common;
use chrono::NaiveDate;
use common::TEST_PRIVATE_KEY_PEM;
use pulse_api::notify::{
    apns::{Apns, ApnsConfig},
    Deliver, Message, SendError,
};
use serde_json::json;
use wiremock::{
    matchers::{method, path},
    Mock, MockServer, ResponseTemplate,
};

const TOKEN: &str = "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abcd";

fn cfg(prod: &str, sandbox: &str) -> ApnsConfig {
    ApnsConfig {
        key_pem: TEST_PRIVATE_KEY_PEM.into(),
        key_id: "KEY123".into(),
        team_id: "TEAM456".into(),
        topic: "org.tsvetkov.eng-pulse".into(),
        production_url: prod.into(),
        sandbox_url: sandbox.into(),
    }
}

fn msg() -> Message {
    Message {
        title: "Title".into(),
        body: "Body".into(),
        feed_slug: "engineering".into(),
        date: NaiveDate::from_ymd_opt(2026, 11, 14).unwrap(),
    }
}

async fn send(server: &MockServer, status: u16, body: serde_json::Value) -> Result<(), SendError> {
    server.reset().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(status).set_body_json(body))
        .mount(server)
        .await;
    let a = Apns::new(cfg(&server.uri(), &server.uri())).unwrap();
    a.push(TOKEN, false, &msg()).await
}

fn jwt_parts(auth: &str) -> (jsonwebtoken::Header, serde_json::Value) {
    let jwt = auth.strip_prefix("bearer ").expect("bearer prefix");
    let head = jsonwebtoken::decode_header(jwt).unwrap();
    let claims = jsonwebtoken::dangerous::insecure_decode::<serde_json::Value>(jwt)
        .unwrap()
        .claims;
    (head, claims)
}

#[tokio::test]
async fn posts_alert_with_required_headers() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path(format!("/3/device/{TOKEN}")))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&s)
        .await;
    let a = Apns::new(cfg(&s.uri(), &s.uri())).unwrap();
    a.push(TOKEN, false, &msg()).await.unwrap();

    let req = &s.received_requests().await.unwrap()[0];
    let h = |k: &str| req.headers.get(k).unwrap().to_str().unwrap().to_string();
    assert_eq!(h("apns-topic"), "org.tsvetkov.eng-pulse");
    assert_eq!(h("apns-push-type"), "alert");
    assert_eq!(h("apns-collapse-id"), "engineering-2026-11-14");
    let exp: i64 = h("apns-expiration").parse().unwrap();
    let want = chrono::Utc::now().timestamp() + 12 * 3600;
    assert!((exp - want).abs() <= 60, "expiration {exp} vs {want}");
    let (head, claims) = jwt_parts(&h("authorization"));
    assert_eq!(head.alg, jsonwebtoken::Algorithm::ES256);
    assert_eq!(head.kid.as_deref(), Some("KEY123"));
    assert_eq!(claims["iss"], "TEAM456");
    assert!(claims["iat"].as_i64().unwrap() > 1_700_000_000);
    let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
    assert_eq!(
        body,
        json!({"aps": {"alert": {"title": "Title", "body": "Body"}, "sound": "default"},
               "feed": "engineering", "date": "2026-11-14"})
    );
}

#[tokio::test]
async fn sandbox_flag_selects_sandbox_url() {
    let (prod, sand) = (MockServer::start().await, MockServer::start().await);
    for s in [&prod, &sand] {
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200))
            .mount(s)
            .await;
    }
    let a = Apns::new(cfg(&prod.uri(), &sand.uri())).unwrap();
    a.push(TOKEN, true, &msg()).await.unwrap();
    assert_eq!(
        (
            prod.received_requests().await.unwrap().len(),
            sand.received_requests().await.unwrap().len()
        ),
        (0, 1)
    );
    a.push(TOKEN, false, &msg()).await.unwrap();
    assert_eq!(prod.received_requests().await.unwrap().len(), 1);
}

#[tokio::test]
async fn status_mapping() {
    let s = MockServer::start().await;
    let r = |reason: &str| json!({ "reason": reason });
    assert!(send(&s, 200, json!({})).await.is_ok());
    assert!(matches!(
        send(&s, 410, r("Unregistered")).await,
        Err(SendError::InvalidToken)
    ));
    assert!(matches!(
        send(&s, 400, r("Unregistered")).await,
        Err(SendError::InvalidToken)
    ));
    for reason in ["BadDeviceToken", "DeviceTokenNotForTopic"] {
        assert!(matches!(
            send(&s, 400, r(reason)).await,
            Err(SendError::InvalidToken)
        ));
    }
    assert!(matches!(
        send(&s, 400, r("PayloadEmpty")).await,
        Err(SendError::Permanent(_))
    ));
    assert!(matches!(
        send(&s, 403, r("InvalidProviderToken")).await,
        Err(SendError::Permanent(_))
    ));
    for st in [404, 413] {
        assert!(matches!(
            send(&s, st, json!({})).await,
            Err(SendError::Permanent(_))
        ));
    }
    for st in [429, 500, 503] {
        assert!(matches!(
            send(&s, st, r("TooManyRequests")).await,
            Err(SendError::Transient(_))
        ));
    }
}

#[tokio::test]
async fn unparsable_400_is_permanent_and_errors_carry_no_secrets() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(400).set_body_string("not json"))
        .mount(&s)
        .await;
    let a = Apns::new(cfg(&s.uri(), &s.uri())).unwrap();
    let Err(SendError::Permanent(e)) = a.push(TOKEN, false, &msg()).await else {
        panic!("expected Permanent");
    };
    assert!(e.contains("400") && !e.contains(TOKEN));

    let Err(SendError::Transient(e)) = Apns::new(cfg("http://127.0.0.1:1", "http://127.0.0.1:1"))
        .unwrap()
        .push(TOKEN, false, &msg())
        .await
    else {
        panic!("expected Transient");
    };
    assert!(!e.contains(TOKEN) && !e.contains("eyJ"));
}

#[tokio::test]
async fn connection_refused_is_transient() {
    let a = Apns::new(cfg("http://127.0.0.1:1", "http://127.0.0.1:1")).unwrap();
    assert!(matches!(
        a.push(TOKEN, false, &msg()).await,
        Err(SendError::Transient(_))
    ));
}

#[tokio::test]
async fn jwt_is_reused_within_50_minutes() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&s)
        .await;
    let a = Apns::new(cfg(&s.uri(), &s.uri())).unwrap();
    a.push(TOKEN, false, &msg()).await.unwrap();
    a.push(TOKEN, false, &msg()).await.unwrap();
    let reqs = s.received_requests().await.unwrap();
    assert_eq!(
        reqs[0].headers.get("authorization"),
        reqs[1].headers.get("authorization")
    );
}

#[tokio::test]
async fn expired_provider_token_is_transient_and_resigns() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(
            ResponseTemplate::new(403).set_body_json(json!({"reason": "ExpiredProviderToken"})),
        )
        .up_to_n_times(1)
        .mount(&s)
        .await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&s)
        .await;
    let a = Apns::new(cfg(&s.uri(), &s.uri())).unwrap();
    assert!(matches!(
        a.push(TOKEN, false, &msg()).await,
        Err(SendError::Transient(_))
    ));
    tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
    a.push(TOKEN, false, &msg()).await.unwrap();
    let reqs = s.received_requests().await.unwrap();
    assert_ne!(
        reqs[0].headers.get("authorization"),
        reqs[1].headers.get("authorization")
    );
}

#[test]
fn new_rejects_a_key_that_is_not_p256_pem() {
    let mut c = cfg("http://x", "http://x");
    c.key_pem = "-----BEGIN PRIVATE KEY-----\nnotakey\n-----END PRIVATE KEY-----".into();
    let Err(e) = Apns::new(c) else {
        panic!("expected error")
    };
    assert!(!e.contains("notakey"));
}

#[tokio::test]
async fn malformed_tokens_are_invalid_without_a_request() {
    let s = MockServer::start().await;
    let a = Apns::new(cfg(&s.uri(), &s.uri())).unwrap();
    for bad in ["../../3/device/x", "abc?x=1", &"a".repeat(63)] {
        assert!(matches!(
            a.push(bad, false, &msg()).await,
            Err(SendError::InvalidToken)
        ));
    }
    assert!(s.received_requests().await.unwrap().is_empty());
}
