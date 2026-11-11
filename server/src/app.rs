use std::sync::Arc;
use std::time::Duration;

use axum::extract::Request;
use axum::http::StatusCode;
use axum::middleware::{from_fn, Next};
use axum::response::Response;
use axum::routing::get;
use axum::Router;

use crate::{cors, db, login, music, playlist, queue, ratelimit, register, respond, session, state, staticfiles};

/// One bucket per endpoint group, so a login flood cannot starve registration and a player
/// that reads its queue cannot stop the library. Separate buckets are the point: a client that
/// builds a playlist should not be able to stop playback.
pub struct Limiters {
    pub register: Arc<ratelimit::RateLimiter>,
    pub login: Arc<ratelimit::RateLimiter>,
    pub session: Arc<ratelimit::RateLimiter>,
    /// Uploads move whole files, so this bucket is smaller on purpose.
    pub upload: Arc<ratelimit::RateLimiter>,
    /// Reading the library and streaming one song are their own buckets, so a client that polls
    /// the list cannot starve playback, and a player that opens several songs cannot starve the
    /// session checks.
    pub library: Arc<ratelimit::RateLimiter>,
    pub stream: Arc<ratelimit::RateLimiter>,
    pub playlist: Arc<ratelimit::RateLimiter>,
    pub queue: Arc<ratelimit::RateLimiter>,
}

pub fn default_limiters() -> Limiters {
    Limiters {
        register: Arc::new(ratelimit::new(5, Duration::from_secs(12))),
        login: Arc::new(ratelimit::new(5, Duration::from_secs(12))),
        session: Arc::new(ratelimit::new(10, Duration::from_secs(12))),
        upload: Arc::new(ratelimit::new(3, Duration::from_secs(30))),
        library: Arc::new(ratelimit::new(10, Duration::from_secs(12))),
        stream: Arc::new(ratelimit::new(10, Duration::from_secs(10))),
        playlist: Arc::new(ratelimit::new(10, Duration::from_secs(12))),
        queue: Arc::new(ratelimit::new(10, Duration::from_secs(12))),
    }
}

/// A generous bucket for tests: a test suite would otherwise answer itself with 429 long
/// before it tests a limit.
pub fn test_limiters() -> Limiters {
    let big = || Arc::new(ratelimit::new(100, Duration::from_secs(1)));
    Limiters {
        register: big(),
        login: big(),
        session: big(),
        upload: big(),
        library: big(),
        stream: big(),
        playlist: big(),
        queue: big(),
    }
}

pub fn app(db: &db::Db, library: &str, static_dir: &str, limiters: &Limiters) -> Router {
    let router = Router::new()
        .merge(register::routes(state::state(db, limiters.register.clone(), library)))
        .merge(login::routes(state::state(db, limiters.login.clone(), library)))
        .merge(session::routes(state::state(db, limiters.session.clone(), library)))
        .merge(music::upload_routes(state::state(db, limiters.upload.clone(), library)))
        .merge(music::list_routes(state::state(db, limiters.library.clone(), library)))
        .merge(music::stream_routes(state::state(db, limiters.stream.clone(), library)))
        .merge(playlist::routes(state::state(db, limiters.playlist.clone(), library)))
        .merge(queue::routes(state::state(db, limiters.queue.clone(), library)))
        .merge(staticfiles::routes(static_dir))
        .route("/", get(root))
        // A path no route owns is answered here rather than by an empty router fallback, so it
        // gives the same plain text 404 the page folder gives for a missing file. A wrong method
        // is not affected: the method router keeps the `Allow` answer the endpoints document.
        .fallback(unknown_path);

    // The page is mounted under its own prefix so it cannot take over a path an API route
    // owns, and the root is the exact root rather than a wildcard: a wrong-method request to an
    // endpoint keeps the method answer the API documents.
    router
        // A path that needs cleaning is answered with the redirect before a handler is chosen, so
        // a ".." element is resolved as part of the path and cannot select a file above the
        // folder the page is served from.
        .layer(from_fn(clean_path))
        // CORS is the outer layer: the preflight is answered before a route is chosen, which
        // is what a browser needs before it sends the real request.
        .layer(from_fn(cors::middleware))
}

/// Forwards a browser tab opened at the root to the page.
async fn root() -> Response {
    respond::redirect(StatusCode::MOVED_PERMANENTLY, "/static/")
}

/// What a path no endpoint owns gets: the plain text 404, because there is no endpoint here that
/// could have failed and therefore no error shape to answer with.
async fn unknown_path() -> Response {
    respond::plain_text(StatusCode::NOT_FOUND, "404 page not found")
}

async fn clean_path(req: Request, next: Next) -> Response {
    let path = req.uri().path();
    let cleaned = staticfiles::clean(path);
    if cleaned != path {
        let target = match req.uri().query() {
            Some(query) => format!("{cleaned}?{query}"),
            None => cleaned,
        };
        return respond::redirect(StatusCode::TEMPORARY_REDIRECT, &target);
    }

    next.run(req).await
}
