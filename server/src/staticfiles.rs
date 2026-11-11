use std::path;

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::get;
use axum::Router;

use crate::respond;

/// The folder the development frontend is served from, relative to the folder the server is
/// started from (`just run` inside `server/`). Nothing here is compiled into the binary, so
/// editing a file and reloading the page is enough.
pub const STATIC_DIR: &str = "static";

/// The prefix the page is mounted under. It is mounted under its own prefix rather than at
/// "/": a route for "/" is a wildcard in the Go version, so it would also answer `/api/*`
/// for a method no endpoint serves, and a wrong-method request would then get the page's plain
/// text 404 instead of the 405 the API documents.
pub const MOUNT: &str = "/static";

#[derive(Clone)]
pub struct StaticState {
    pub dir: String,
}

pub fn routes(dir: &str) -> Router {
    Router::new()
        .route(MOUNT, get(handle))
        .route(&format!("{MOUNT}/"), get(handle))
        .route(&format!("{MOUNT}/{{*rest}}"), get(handle))
        .with_state(StaticState { dir: dir.to_string() })
}

/// Serves one file of the page. A missing file gets the plain text 404 rather than the JSON
/// error shape, because this is not an API endpoint. `X-Content-Type-Options` is still set, as
/// on every other answer from this server.
pub async fn handle(State(state): State<StaticState>, req: Request) -> Response {
    // The path is cleaned before a file is opened, so a ".." element cannot select one above
    // the folder. The redirect for an unclean path is answered by the route layer in `app`,
    // which is what a router does; here the path is only resolved.
    let requested = under_mount(req.uri().path());
    let name = clean(&requested);

    // The index file is the folder, so the page keeps one address: a link in the HTML must not
    // quietly point at a redirect.
    if name.ends_with("/index.html") {
        return respond::redirect(StatusCode::MOVED_PERMANENTLY, "./");
    }

    let mut file = path::Path::new(&state.dir).join(name.trim_start_matches('/'));
    let mut metadata = match tokio::fs::metadata(&file).await {
        Ok(metadata) => metadata,
        Err(_) => return not_found(),
    };

    // A directory is served through its index file, as the page's own links expect.
    if metadata.is_dir() {
        file = path::Path::join(&file, "index.html");
        metadata = match tokio::fs::metadata(&file).await {
            Ok(metadata) => metadata,
            Err(_) => return not_found(),
        };
    }

    let bytes = match tokio::fs::read(&file).await {
        Ok(bytes) => bytes,
        Err(_) => return not_found(),
    };

    let length = metadata.len().to_string();
    respond::with_body(
        StatusCode::OK,
        &[("content-type", content_type(&file)), ("content-length", length.as_str())],
        Body::from(bytes),
    )
}

/// The part of the path below the mount, always rooted.
pub fn under_mount(full: &str) -> String {
    match full.strip_prefix(MOUNT) {
        Some(rest) => ensure_root(rest),
        None => ensure_root(full),
    }
}

/// Removes "." and ".." elements, the way a router resolves a path before it opens a file.
pub fn clean(value: &str) -> String {
    let rooted = ensure_root(value);
    let mut parts: Vec<&str> = Vec::new();
    for part in rooted.split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            parts.pop();
            continue;
        }
        parts.push(part);
    }

    let mut cleaned = format!("/{}", parts.join("/"));

    // A path that was rooted stays rooted; the trailing slash is kept because it is part of
    // what the client asked for. An empty path is the root itself, so it must not get a second
    // slash: that would make "/" look like a path that still needs cleaning.
    if rooted.ends_with('/') && !cleaned.ends_with('/') {
        cleaned.push('/');
    }

    cleaned
}

fn ensure_root(value: &str) -> String {
    if value.starts_with('/') {
        value.to_string()
    } else {
        format!("/{value}")
    }
}

fn content_type(target: &path::Path) -> &'static str {
    match target.extension().and_then(|ext| ext.to_str()) {
        Some("html") => "text/html; charset=utf-8",
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("json") => "application/json",
        _ => "text/plain; charset=utf-8",
    }
}

fn not_found() -> Response {
    respond::plain_text(StatusCode::NOT_FOUND, &[], "404 page not found")
}
