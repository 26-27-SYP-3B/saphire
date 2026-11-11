mod common;

use axum::http::StatusCode;

// The root is the exact root, so a browser tab opened at "/" reaches the page without the page
// taking over an API path. An API path answered with a method no endpoint serves keeps the
// method answer the API documents.
#[tokio::test]
async fn the_root_forwards_a_browser_to_the_page_without_taking_over_an_api_path() {
    let test = common::setup().await;

    let reply = common::get(&test, "/", "").await;
    assert_eq!(reply.status, StatusCode::MOVED_PERMANENTLY, "GET / -> {} ({})", reply.status, reply.body);
    assert_eq!(
        common::header(&reply, "location"),
        "/static/",
        "GET / answered Location {:?}",
        common::header(&reply, "location")
    );

    let reply = common::get(&test, "/api/register", "").await;
    assert_eq!(reply.status, StatusCode::METHOD_NOT_ALLOWED, "GET /api/register -> {} ({})", reply.status, reply.body);
    assert!(common::header(&reply, "allow").contains("POST"), "405 must say which method the path serves: {:?}", reply.headers);

    // The page itself still answers.
    let reply = common::get(&test, "/static/", "").await;
    assert_eq!(reply.status, StatusCode::OK, "GET /static/ -> {} ({})", reply.status, reply.body);
}

// A path no endpoint owns is not an endpoint, so it cannot fail one: it gets the plain text 404
// the page folder gives for a missing file. These two answers are built by the router without a
// handler, so the header the API documents for every answer has to come from the layer rather
// than from a handler.
#[tokio::test]
async fn an_answer_without_a_handler_keeps_the_documented_shape() {
    let test = common::setup().await;

    let reply = common::get(&test, "/api/nothing", "").await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "GET /api/nothing -> {} ({})", reply.status, reply.body);
    assert!(
        common::header(&reply, "content-type").contains("text/plain"),
        "a path that is not an endpoint answers as text, not as the JSON error shape: {:?}",
        reply.headers
    );
    assert_eq!(reply.body, "404 page not found", "unexpected body for an unknown path: {}", reply.body);

    for path in ["/api/nothing", "/api/register"] {
        let reply = common::get(&test, path, "").await;
        assert_eq!(
            common::header(&reply, "x-content-type-options"),
            "nosniff",
            "{path} answered without the header the API documents for every answer: {:?}",
            reply.headers
        );
    }
}
