mod common;

use axum::http::StatusCode;

// The CORS layer is part of the app, so the preflight and the real request are tested through
// the same combination the server runs with.
#[tokio::test]
async fn a_preflight_answers_the_permission_and_names_the_origin_it_reflected() {
    let test = common::setup().await;

    let reply = common::call(
        &test,
        "OPTIONS",
        "/api/register",
        b"",
        &[
            ("origin", "http://localhost:53736"),
            ("access-control-request-method", "POST"),
        ],
    )
    .await;

    assert_eq!(reply.status, StatusCode::NO_CONTENT, "preflight -> {} ({})", reply.status, reply.body);
    assert_eq!(
        common::header(&reply, "access-control-allow-origin"),
        "http://localhost:53736",
        "origin not reflected: {:?}",
        reply.headers
    );
    assert!(
        common::header(&reply, "access-control-allow-methods").contains("POST"),
        "preflight must allow POST: {:?}",
        reply.headers
    );
    assert!(
        common::header(&reply, "access-control-allow-headers").contains("Content-Type"),
        "preflight must allow the JSON content type: {:?}",
        reply.headers
    );
    assert_eq!(
        common::header(&reply, "vary"),
        "Origin",
        "reflected origins need Vary: Origin so caches do not mix them: {:?}",
        reply.headers
    );
    assert_eq!(
        common::header(&reply, "x-content-type-options"),
        "nosniff",
        "the preflight is answered by this layer, so the header the API documents for every answer belongs on it: {:?}",
        reply.headers
    );
}

// The real request needs its own header too; the preflight alone does not let the browser read
// the answer.
#[tokio::test]
async fn the_real_request_answers_the_origin_it_was_sent_with() {
    let test = common::setup().await;

    let reply = common::call(
        &test,
        "POST",
        "/api/register",
        r#"{"username": "testuser", "password": "geheim123"}"#.as_bytes(),
        &[("origin", "http://localhost:53736")],
    )
    .await;
    assert_eq!(reply.status, StatusCode::CREATED, "register through the CORS layer -> {} ({})", reply.status, reply.body);
    assert_eq!(
        common::header(&reply, "access-control-allow-origin"),
        "http://localhost:53736",
        "a real request without the origin header would be blocked in the browser: {:?}",
        reply.headers
    );

    // A non-browser client sends no Origin: then no CORS headers belong on the answer, and the
    // endpoint must still work.
    let reply = common::post(
        &test,
        "/api/register",
        r#"{"username": "otheruser", "password": "geheim123"}"#,
        "",
    )
    .await;
    assert_eq!(reply.status, StatusCode::CREATED, "register without an origin -> {} ({})", reply.status, reply.body);
    assert_eq!(common::header(&reply, "access-control-allow-origin"), "", "no origin was sent, so none should be answered: {:?}", reply.headers);
}
