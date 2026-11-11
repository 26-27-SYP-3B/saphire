mod common;

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::StatusCode;
use saphire_server::{app, staticfiles};

/// The page the tests serve: three files in a folder of their own, so a test can tell the page
/// apart from a file that is not there. The app is rebuilt with this folder, because the tests
/// then know exactly what is being served.
fn page(test: &mut common::Test, dir: &tempfile::TempDir) {
    for (name, content) in [
        ("index.html", "<!doctype html><title>Saphire dev console</title>"),
        ("app.js", "console.log(\"dev console\");"),
        ("style.css", "body { color: #111; }"),
    ] {
        std::fs::write(dir.path().join(name), content).expect("write the file");
    }

    test.app = app::app(&test.db, &test.library.to_string_lossy(), &dir.path().to_string_lossy(), &app::test_limiters());
}

#[tokio::test]
async fn the_page_answers_its_own_files_and_refuses_what_is_not_there() {
    let mut test = common::setup().await;
    let dir = tempfile::TempDir::new().expect("the test page folder");
    page(&mut test, &dir);

    let cases = [
        ("/static/", StatusCode::OK, "text/html"),
        // The index file redirects to its folder, so the page has one address. The test below
        // checks where it redirects to.
        ("/static/index.html", StatusCode::MOVED_PERMANENTLY, ""),
        ("/static/app.js", StatusCode::OK, "javascript"),
        ("/static/style.css", StatusCode::OK, "css"),
        ("/static/missing.html", StatusCode::NOT_FOUND, ""),
    ];

    for (path, want, content_type) in cases {
        let reply = common::get(&test, path, "").await;
        assert_eq!(reply.status, want, "GET {path} -> {} ({})", reply.status, reply.body);

        if !content_type.is_empty() {
            assert!(
                common::header(&reply, "content-type").contains(content_type),
                "GET {path} served as {:?}, wanted {content_type}",
                common::header(&reply, "content-type")
            );
        }

        // A missing file is the plain text 404 rather than the JSON error shape, because this
        // is not an API endpoint — but nosniff still belongs on the answer.
        assert_eq!(
            common::header(&reply, "x-content-type-options"),
            "nosniff",
            "GET {path} without nosniff: {:?}",
            reply.headers
        );
    }
}

// The index file is the folder, so the page keeps one address: a link in the HTML must not
// quietly point at a redirect.
#[tokio::test]
async fn the_index_file_redirects_to_the_page_address() {
    let mut test = common::setup().await;
    let dir = tempfile::TempDir::new().expect("the test page folder");
    page(&mut test, &dir);

    let reply = common::get(&test, "/static/index.html", "").await;
    assert_eq!(reply.status, StatusCode::MOVED_PERMANENTLY, "GET /static/index.html -> {} ({})", reply.status, reply.body);
    assert_eq!(common::header(&reply, "location"), "./", "the redirect went to {:?}", common::header(&reply, "location"));
}

// The page must not take over a path an API route owns. This is why it is mounted under a
// prefix: a wrong-method request to an endpoint keeps the method answer the API documents.
#[tokio::test]
async fn the_page_does_not_take_over_an_api_path() {
    let test = common::setup().await;

    let reply = common::post(
        &test,
        "/api/register",
        r#"{"username": "testuser", "password": "geheim123"}"#,
        "",
    )
    .await;
    assert_eq!(reply.status, StatusCode::CREATED, "register through the app -> {} ({})", reply.status, reply.body);

    let reply = common::get(&test, "/api/register", "").await;
    assert_eq!(reply.status, StatusCode::METHOD_NOT_ALLOWED, "GET /api/register -> {} ({})", reply.status, reply.body);
    assert!(
        common::header(&reply, "allow").contains("POST"),
        "GET /api/register -> {} with Allow {:?}, wanted 405 allowing POST ({})",
        reply.status,
        reply.headers,
        reply.body
    );

    // Only GET serves the page.
    let reply = common::post(&test, "/static/", "{}", "").await;
    assert_eq!(reply.status, StatusCode::METHOD_NOT_ALLOWED, "POST /static/ -> {} ({})", reply.status, reply.body);

    // The page itself still answers.
    let reply = common::get(&test, "/static/", "").await;
    assert_eq!(reply.status, StatusCode::OK, "GET /static/ -> {} ({})", reply.status, reply.body);
}

// The page is mounted under a prefix, so its links must be relative to the page. An absolute
// "/app.js" is outside the mount: the browser gets the 404 as text/plain and refuses to run the
// script, so the page loads and does nothing.
#[tokio::test]
async fn the_page_links_stay_relative() {
    let page = std::fs::read_to_string(common::page_file("index.html")).expect("read the page");

    for marker in ["href=\"", "src=\""] {
        for (index, _) in page.match_indices(marker) {
            let link = page[index + marker.len()..].split('"').next().unwrap_or_default();
            assert!(
                !link.starts_with('/'),
                "link {link:?} is absolute; it must be relative to the page so it resolves under the mount",
            );
        }
    }
}

// The file root is the folder itself: the handler cleans the path before it opens a file, so a
// ".." element cannot select one above the folder. The router answers an unclean path with a
// redirect before a handler is chosen, which is what a router does — so the same path is 307
// through the app and 404 when the handler is asked alone. Following the redirect still cannot
// serve a file from outside the folder.
#[tokio::test]
async fn the_page_stays_in_its_folder() {
    let mut test = common::setup().await;
    let dir = tempfile::TempDir::new().expect("the test page folder");
    page(&mut test, &dir);

    let parent = dir.path().parent().expect("the folder above the page");
    std::fs::write(parent.join("outside.html"), "<title>outside</title>").expect("write the outside file");

    let state = staticfiles::StaticState { dir: dir.path().to_string_lossy().to_string() };
    let request = Request::builder().uri("/static/../outside.html").body(Body::empty()).expect("build the request");
    let response = staticfiles::handle(State(state), request).await;
    assert_eq!(response.status(), StatusCode::NOT_FOUND, "the handler alone served a file above the folder");

    let reply = common::get(&test, "/static/../outside.html", "").await;
    assert_eq!(reply.status, StatusCode::TEMPORARY_REDIRECT, "an unclean path -> {} ({})", reply.status, reply.body);

    // The ".." is resolved before anything is opened, so the answer cannot name a file above the
    // folder the page is served from.
    let target = common::header(&reply, "location");
    assert!(!target.contains(".."), "the redirect still carries the element that reaches above the folder: {target:?}");

    let reply = common::get(&test, &target, "").await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "following {target} served a file outside the folder ({})", reply.body);
}
