mod common;

use std::sync::Arc;
use std::time::Duration;

use axum::http::StatusCode;
use saphire_server::{app, clock, db, ratelimit, session};

#[tokio::test]
async fn login_answers_by_the_documented_rules() {
    // Big capacity so only the request bodies and the credentials decide the status.
    let test = common::setup().await;

    let cases = [
        // Unknown user and wrong password answer the same, so a caller cannot enumerate usernames.
        (r#"{"username": "lukas", "password": "wrong-password"}"#, StatusCode::UNAUTHORIZED),
        // Normalized before lookup, so the same name in another spelling is the same user.
        (r#"{"username": "LUKAS", "password": "wrong-password"}"#, StatusCode::UNAUTHORIZED),
        // Same field rules as registration, because there is one source for them.
        (r#"{"username": "ab", "password": "valid-password"}"#, StatusCode::BAD_REQUEST),
        (r#"{"username": "lukas", "password": "short"}"#, StatusCode::BAD_REQUEST),
        ("not json", StatusCode::BAD_REQUEST),
    ];

    for (body, want) in cases {
        let reply = common::post(&test, "/api/login", body, "").await;
        assert_eq!(reply.status, want, "POST {body} -> {} ({})", reply.status, reply.body);
    }

    // Register, then log in with the same credentials.
    let created = common::post(&test, "/api/register", r#"{"username": "lukas", "password": "secure-pass-123"}"#, "").await;
    assert_eq!(created.status, StatusCode::CREATED, "register -> {} ({})", created.status, created.body);

    let reply = common::post(&test, "/api/login", r#"{"username": "lukas", "password": "secure-pass-123"}"#, "").await;
    assert_eq!(reply.status, StatusCode::OK, "login -> {} ({})", reply.status, reply.body);

    let login = common::json(&reply.body);
    let token = login["token"].as_str().expect("the answer has a token").to_string();
    let expires_at = login["expires_at"].as_i64().expect("the answer has an expires_at");

    // 32 random bytes as hex, nothing predictable about it.
    assert!(
        token.len() == 64 && token.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f')),
        "token is not 64 hex characters: {token}",
    );

    let now = clock::unix_now();
    assert!(
        expires_at > now && expires_at <= now + session::SESSION_TTL_SECONDS,
        "expires_at is not within the session TTL: {expires_at}",
    );

    // The stored row holds only the hash, never the token itself.
    let stored = common::run(&test, |conn| {
        let stored: String = conn
            .query_row("SELECT token_hash FROM session", (), |row| row.get(0))
            .map_err(db::failure)?;
        Ok(stored)
    })
    .await;
    assert_eq!(stored, session::hash_token(&token), "session stores {stored}, wanted the hash of the token");

    // The token authenticates at GET /api/session.
    let reply = common::get(&test, "/api/session", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "session -> {} ({})", reply.status, reply.body);

    let caller = common::json(&reply.body);
    let user_id = caller["id"].as_i64().unwrap_or(0);
    assert!(user_id > 0, "session names the wrong user: {}", reply.body);
    assert_eq!(caller["username"].as_str(), Some("lukas"), "session names the wrong user: {}", reply.body);
    assert!(!reply.body.contains("password"), "answer must not contain the password hash: {}", reply.body);

    // A missing header is its own error, so the client knows what to fix.
    let reply = common::get(&test, "/api/session", "").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "no header -> {} ({})", reply.status, reply.body);

    // An expired session is refused and dropped from the table. The raw token
    // is used here because the hash cannot be turned back into one.
    let raw_token = "f".repeat(64);
    let expired = session::Session {
        token_hash: session::hash_token(&raw_token),
        user_id,
        created_at: now - 2 * session::SESSION_TTL_SECONDS,
        expires_at: now - session::SESSION_TTL_SECONDS,
    };

    common::run(&test, move |conn| {
        session::insert(conn, &expired)?;
        Ok(())
    })
    .await;

    let reply = common::get(&test, "/api/session", &raw_token).await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "expired session -> {} ({})", reply.status, reply.body);

    // Only the session of the real login is left, so the expired row was dropped by the lookup.
    assert_eq!(common::count(&test, "session").await, 1, "expired session was not dropped");
}

#[tokio::test]
async fn login_is_rate_limited_per_address() {
    // A wide refill window on purpose: every login hashes a password, which takes noticeable
    // time, so with a one second window the tokens between two requests would depend on how
    // fast this machine hashes. A long window makes the test measure the limit, not the hash.
    let mut limiters = app::test_limiters();
    limiters.login = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&limiters).await;

    // The first two are allowed even though they fail for other reasons — the limiter decides
    // first, so brute-force guessing is what costs tokens.
    for request in 1..=2 {
        let reply = common::post(&test, "/api/login", r#"{"username": "nobody", "password": "valid-password"}"#, "").await;
        assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "request {request} -> {} ({})", reply.status, reply.body);
    }

    let reply = common::post(&test, "/api/login", r#"{"username": "nobody", "password": "valid-password"}"#, "").await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third request -> {} ({})", reply.status, reply.body);
    common::check_retry_after(&reply, 60);
}
