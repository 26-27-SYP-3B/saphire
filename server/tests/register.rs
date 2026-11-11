mod common;

use std::sync::Arc;
use std::time::Duration;

use axum::http::StatusCode;
use saphire_server::{app, ratelimit};

#[tokio::test]
async fn register_answers_by_the_documented_rules() {
    // Big capacity so only the request bodies decide the status.
    let test = common::setup().await;

    let cases = [
        (
            r#"{"username": "lukas", "password": "secure-pass-123"}"#,
            StatusCode::CREATED,
        ),
        // Case-insensitive uniqueness: the same name in another spelling is the same user.
        (
            r#"{"username": "LUKAS", "password": "another-password"}"#,
            StatusCode::CONFLICT,
        ),
        (r#"{"username": "nina", "password": "short"}"#, StatusCode::BAD_REQUEST),
        // 72 bytes are the last value bcrypt still reads; a longer input is rejected, not
        // truncated, and an unknown field is not accepted either.
        (
            r#"{"username": "nina", "password": "exactly-72-characters-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "extra": true}"#,
            StatusCode::BAD_REQUEST,
        ),
        (r#"{"username": "ma ria", "password": "valid-password"}"#, StatusCode::BAD_REQUEST),
        (r#"{"username": "ab", "password": "valid-password"}"#, StatusCode::BAD_REQUEST),
        ("not json", StatusCode::BAD_REQUEST),
    ];

    for (body, want) in cases {
        let reply = common::post(&test, "/api/register", body, "").await;
        assert_eq!(reply.status, want, "POST {body} -> {} ({})", reply.status, reply.body);
    }

    // The client form shows the id, so the answer has to carry it — but never the hash.
    let reply = common::post(&test, "/api/register", r#"{"username": "Nina.", "password": "valid-password"}"#, "").await;
    assert_eq!(reply.status, StatusCode::CREATED, "wanted 201 ({})", reply.body);

    let created = common::json(&reply.body);
    assert!(created["id"].as_i64().unwrap_or(0) > 0, "answer has no id: {}", reply.body);
    assert_eq!(
        created["username"].as_str(),
        Some("nina."),
        "username was not normalized to lowercase: {}",
        reply.body
    );
    assert!(
        !reply.body.contains("password"),
        "answer must not contain the password hash: {}",
        reply.body
    );
}

// The 409 says what the client can act on, not what the database enforces. The wording here is
// the one api-docs.md documents, so the client form can show it under the field.
#[tokio::test]
async fn a_taken_username_is_named_without_naming_the_constraint() {
    let test = common::setup().await;

    let reply = common::post(&test, "/api/register", r#"{"username": "lukas", "password": "secure-pass-123"}"#, "").await;
    assert_eq!(reply.status, StatusCode::CREATED, "wanted 201 ({})", reply.body);

    let reply = common::post(&test, "/api/register", r#"{"username": "LUKAS", "password": "another-password"}"#, "").await;
    assert_eq!(reply.status, StatusCode::CONFLICT, "wanted 409 ({})", reply.body);
    assert_eq!(
        common::json(&reply.body)["error"].as_str(),
        Some("username is not available"),
        "the 409 must answer the documented wording, not a driver string: {}",
        reply.body
    );
}

// The rate limiter buckets per address, so the peer address must be read for IPv6 too — a
// bracketed address must not fall into the shared unknown bucket, and a port is not part of
// an address.
#[test]
fn a_peer_key_is_the_address_without_the_port() {
    let cases = [
        ("127.0.0.1:8080", "127.0.0.1"),
        ("[::1]:8080", "::1"),
        ("[2001:db8::1]:443", "2001:db8::1"),
        // A zone belongs to the address, so it belongs to the key.
        ("[fe80::1%eth0]:8080", "fe80::1%eth0"),
        ("[::1]", "::1"), // bracketed without a port
    ];

    for (remote, want) in cases {
        assert_eq!(ratelimit::peer_key(remote), want, "peer_key({remote})");
    }
}

#[tokio::test]
async fn register_is_rate_limited_per_address() {
    // A wide refill window on purpose: every registration hashes a password, which takes
    // noticeable time, so with a one second window the tokens between two requests would
    // depend on how fast this machine hashes. A long window makes the test measure the limit,
    // not the hash.
    let mut limiters = app::test_limiters();
    limiters.register = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&limiters).await;

    for name in ["usera", "userb"] {
        let reply = common::post(
            &test,
            "/api/register",
            &format!(r#"{{"username": "{name}", "password": "valid-password"}}"#),
            "",
        )
        .await;
        assert_eq!(reply.status, StatusCode::CREATED, "{name} -> {} ({})", reply.status, reply.body);
    }

    let reply = common::post(&test, "/api/register", r#"{"username": "userzz", "password": "valid-password"}"#, "").await;
    assert_eq!(
        reply.status,
        StatusCode::TOO_MANY_REQUESTS,
        "third request -> {} ({})",
        reply.status,
        reply.body
    );
    common::check_retry_after(&reply, 60);
}
