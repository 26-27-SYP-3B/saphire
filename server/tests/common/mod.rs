// The helpers are shared by every test file, so a single test binary never uses all of them.
#![allow(dead_code)]

use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use axum::body::Body;
use axum::extract::{ConnectInfo, Request};
use axum::http::{HeaderMap, StatusCode};
use axum::Router;
use http_body_util::BodyExt;
use serde_json::Value;
use saphire_server::{app, db, respond::Failure};
use tokio_rusqlite::rusqlite;
use tower::ServiceExt;

/// One answer of the test app, read the way a client reads it.
pub struct Reply {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: String,
}

/// A test run: an in-memory database, its own library folder, and the app exactly as the server
/// builds it — including the path cleaning and the CORS layer, because a preflight can only be
/// tested through the same combination the server runs with.
pub struct Test {
    pub app: Router,
    pub db: db::Db,
    pub library: PathBuf,
    // Kept so the folder lives as long as the test.
    temp: tempfile::TempDir,
}

pub async fn setup() -> Test {
    setup_with(&app::test_limiters()).await
}

/// A run with its own buckets, for the tests that test a limit.
pub async fn setup_with(limiters: &app::Limiters) -> Test {
    let database = db::open_db_with(":memory:").await.expect("open the test database");
    let temp = tempfile::TempDir::new().expect("create the test library");

    Test {
        app: app::app(&database, &temp.path().to_string_lossy(), "static", limiters),
        db: database,
        library: temp.path().to_path_buf(),
        temp,
    }
}

/// The peer a test request comes from. Without a `ConnectInfo` every request would share one
/// bucket, so a limit test would measure nothing.
pub fn peer() -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], 8080))
}

/// One request, with whatever headers the test needs.
pub async fn call(test: &Test, method: &str, path: &str, body: &[u8], headers: &[(&str, &str)]) -> Reply {
    let mut builder = Request::builder().method(method).uri(path);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }

    let mut request = builder.body(Body::from(body.to_vec())).expect("build the request");
    request.extensions_mut().insert(ConnectInfo(peer()));

    let response = test.app.clone().oneshot(request).await.expect("send the request");
    let (parts, body) = response.into_parts();
    let bytes = body.collect().await.expect("read the body").to_bytes();

    Reply {
        status: parts.status,
        headers: parts.headers,
        body: String::from_utf8_lossy(&bytes).to_string(),
    }
}

pub async fn post(test: &Test, path: &str, body: &str, token: &str) -> Reply {
    let mut headers = Vec::new();
    if !token.is_empty() {
        headers.push(("authorization", format!("Bearer {token}")));
    }
    call_with_headers(test, "POST", path, body.as_bytes(), &headers).await
}

pub async fn get(test: &Test, path: &str, token: &str) -> Reply {
    let mut headers = Vec::new();
    if !token.is_empty() {
        headers.push(("authorization", format!("Bearer {token}")));
    }
    call_with_headers(test, "GET", path, b"", &headers).await
}

pub async fn delete(test: &Test, path: &str, token: &str) -> Reply {
    let mut headers = Vec::new();
    if !token.is_empty() {
        headers.push(("authorization", format!("Bearer {token}")));
    }
    call_with_headers(test, "DELETE", path, b"", &headers).await
}

async fn call_with_headers(test: &Test, method: &str, path: &str, body: &[u8], headers: &[(&str, String)]) -> Reply {
    let owned: Vec<(&str, &str)> = headers.iter().map(|(name, value)| (*name, value.as_str())).collect();
    call(test, method, path, body, &owned).await
}

const BOUNDARY: &str = "testboundary";

/// One multipart upload. `file_name == ""` sends the field as a plain form value;
/// `field == ""` sends an empty multipart body.
pub async fn upload(test: &Test, token: &str, field: &str, file_name: &str, content: &[u8]) -> Reply {
    let mut body: Vec<u8> = Vec::new();
    if !field.is_empty() {
        if file_name.is_empty() {
            body.extend_from_slice(format!("--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"{field}\"\r\n\r\nnot a file\r\n").as_bytes());
        } else {
            body.extend_from_slice(format!("--{BOUNDARY}\r\nContent-Disposition: form-data; name=\"{field}\"; filename=\"{file_name}\"\r\n\r\n").as_bytes());
            body.extend_from_slice(content);
            body.extend_from_slice(b"\r\n");
        }
    }
    if !body.is_empty() {
        body.extend_from_slice(format!("--{BOUNDARY}--\r\n").as_bytes());
    }

    let mut headers = vec![("content-type", format!("multipart/form-data; boundary={BOUNDARY}"))];
    if !token.is_empty() {
        headers.push(("authorization", format!("Bearer {token}")));
    }

    call_with_headers(test, "POST", "/api/music/upload", &body, &headers).await
}

/// Registers a user and logs in, returning the token the client would keep.
pub async fn token(test: &Test, username: &str, password: &str) -> String {
    let created = post(
        test,
        "/api/register",
        &format!(r#"{{"username": "{username}", "password": "{password}"}}"#),
        "",
    )
    .await;
    assert_eq!(created.status, StatusCode::CREATED, "register: {}", created.body);

    let logged = post(
        test,
        "/api/login",
        &format!(r#"{{"username": "{username}", "password": "{password}"}}"#),
        "",
    )
    .await;
    assert_eq!(logged.status, StatusCode::OK, "login: {}", logged.body);

    json(&logged.body)["token"].as_str().expect("the answer has a token").to_string()
}

pub fn json(body: &str) -> Value {
    serde_json::from_str(body).expect("the answer is JSON")
}

/// Reads an answer into the model the endpoint documents, so a test checks the same fields a client reads.
pub fn decode<T: serde::de::DeserializeOwned>(body: &str) -> T {
    serde_json::from_str(body).expect("the answer is JSON")
}

/// The smallest recognizable audio file: a RIFF/WAVE header plus four samples.
pub fn tiny_wav() -> Vec<u8> {
    b"RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00data\x04\x00\x00\x00\x00\x00\x00\x00".to_vec()
}

/// Binary content that no audio format can claim.
pub fn not_audio() -> Vec<u8> {
    vec![1, 2, 3, 4, 5, 6, 7, 8]
}

/// Asserts a rate-limited answer carries an honest `Retry-After`: the seconds until the next
/// token, which for a token bucket is at most the refill window. It must not be a fixed guess
/// that overstates the wait.
pub fn check_retry_after(reply: &Reply, window_seconds: u64) {
    let sent = reply
        .headers
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<u64>().ok());

    assert!(
        matches!(sent, Some(seconds) if seconds >= 1 && seconds <= window_seconds),
        "Retry-After {sent:?} must be a positive value within the {window_seconds} s refill window",
    );
}

/// Reads or writes the database directly, for the rules a test must not take on trust: that a
/// hash is stored instead of a token, that a row is really gone. The statement is written the
/// same way the server writes it — parameterized.
pub async fn run<R: Send + 'static>(test: &Test, f: impl FnOnce(&mut rusqlite::Connection) -> Result<R, Failure> + Send + 'static) -> R {
    let db = test.db.clone();

    db::call(&db, f).await.expect("the statement failed")
}

pub async fn count(test: &Test, table: &str) -> i64 {
    let table = table.to_string();

    run(test, move |conn| {
        let value: i64 = conn
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), (), |row| row.get(0))
            .map_err(db::failure)?;
        Ok(value)
    })
    .await
}

/// A file of the development page, for the tests that check what the page links to.
pub fn page_file(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("static").join(name)
}

/// One header of an answer, as a test reads it.
pub fn header(reply: &Reply, name: &str) -> String {
    reply
        .headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string()
}
