use std::fmt;

use axum::body::Body;
use axum::http::{Response, StatusCode};
use serde::Serialize;
use serde_json::json;

use crate::{playlist, queue};

/// What a domain function can report. Each variant is a reason the answer can name, so the
/// client is told which one it is instead of a driver error. The numbers in the text come
/// from the same constants the checks use, so raising a cap would make the answer lie.
///
/// `Db` keeps the driver text for the log only. An answer never repeats it: an error says
/// what happened and the fix, not what went wrong inside the server.
#[derive(Debug)]
pub enum Failure {
    /// A parameterized lookup found no row. What that means for the caller is its own
    /// decision, so this variant carries no wording of its own.
    NoRows,
    /// A UNIQUE constraint. The only one the server can answer with a name is the username, so
    /// the wording here is the one `api-docs.md` documents for `POST /api/register`.
    Unique,
    /// The Authorization header did not carry a Bearer token.
    MissingAuthHeader,
    /// The token is unknown, expired, or its user is gone.
    SessionNotFound,
    SessionDb,
    UserDb,
    PlaylistNotYours,
    SongNotInLibrary,
    /// Names the slot it is about, so the answer says which position was empty and in what
    /// instead of a plain "not found". The position stays i64 because it comes from a path
    /// value that was parsed as one.
    PositionNotThere { container: &'static str, position: i64 },
    PlaylistFull,
    QueueFull,
    /// A queue source the server does not know. The handler names it before resolving the
    /// source, so the same wording is seen from either place.
    QueueSource,
    Db(String),
}

impl fmt::Display for Failure {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Failure::NoRows => write!(f, "no row"),
            Failure::Unique => write!(f, "username is not available"),
            Failure::MissingAuthHeader => write!(f, "authorization header with a Bearer token is missing"),
            Failure::SessionNotFound => write!(f, "session is not valid or expired"),
            Failure::SessionDb => write!(f, "could not load session"),
            Failure::UserDb => write!(f, "could not load user"),
            Failure::PlaylistNotYours => write!(f, "playlist is not in your playlists"),
            Failure::SongNotInLibrary => write!(f, "song is not in the library"),
            Failure::PositionNotThere { container, position } => {
                write!(f, "no song at position {position} in this {container}")
            }
            Failure::PlaylistFull => write!(f, "a playlist holds at most {} songs", playlist::MAX_SONGS),
            Failure::QueueFull => write!(f, "the queue holds at most {} songs", queue::MAX_ENTRIES),
            Failure::QueueSource => write!(f, "{}", queue::source_message()),
            Failure::Db(text) => write!(f, "{text}"),
        }
    }
}

/// Every answer that is JSON goes through here, so the content type and
/// `X-Content-Type-Options` are never forgotten.
pub fn json<T: Serialize>(status: StatusCode, value: &T) -> Response<Body> {
    build(status, &[("content-type", "application/json")], &serde_json::to_vec(value).unwrap_or_default())
}

/// An answer whose body is not JSON — the streamed file of a song. `X-Content-Type-Options`
/// is added here too, because every answer from this server carries it.
pub fn with_body(status: StatusCode, headers: &[(&str, &str)], body: Body) -> Response<Body> {
    let mut builder = Response::builder().status(status);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    builder
        .header("x-content-type-options", "nosniff")
        .body(body)
        .expect("a response with a status and known header names")
}


/// An answer whose body is plain text — a path no endpoint owns, or a byte range a player asked
/// for that the file cannot answer. The JSON error shape belongs to the documented endpoints, so
/// a failure of the transport is not one of its errors. `headers` is for the plain-text answer
/// that still has to name something, such as the size a rejected range was measured against;
/// pass `&[]` when there is nothing extra to say.
pub fn plain_text(status: StatusCode, headers: &[(&str, &str)], message: &str) -> Response<Body> {
    let mut all = vec![("content-type", "text/plain; charset=utf-8")];
    all.extend(headers);
    with_body(status, &all, Body::from(message.to_string()))
}

/// The `{"error": "…"}` body that the client form shows below its fields.
pub fn error(status: StatusCode, message: &str) -> Response<Body> {
    json(status, &json!({ "error": message }))
}

/// A rate-limited answer. The seconds until the next token belong in `Retry-After`, so the
/// client is told how long it actually has to wait instead of a fixed guess.
pub fn rate_limited(message: &str, retry_after: u64) -> Response<Body> {
    build(
        StatusCode::TOO_MANY_REQUESTS,
        &[
            ("content-type", "application/json"),
            ("retry-after", &retry_after.to_string()),
        ],
        &serde_json::to_vec(&json!({ "error": message })).unwrap_or_default(),
    )
}

/// A successful delete. There is no body, so the content type must not be set: a 204 that
/// claims one is what a client has to read as "nothing to parse".
pub fn no_content() -> Response<Body> {
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .body(Body::empty())
        .expect("a response with only a status")
}

/// A redirect. Only `Location` is answered, with no body, so a client reads it as the address
/// it should ask again rather than as content.
pub fn redirect(status: StatusCode, location: &str) -> Response<Body> {
    Response::builder()
        .status(status)
        .header("location", location)
        .header("x-content-type-options", "nosniff")
        .body(Body::empty())
        .expect("a response with a status and known header names")
}

/// The answer a domain error gets. `db_message` is what this endpoint calls a database
/// failure, because that wording belongs to the endpoint, not to the lookup. A caller that
/// means something else by "no row" names it before returning, so what reaches here is the
/// wording this endpoint documented.
pub fn answer(err: &Failure, db_message: &str) -> Response<Body> {
    let status = match err {
        Failure::MissingAuthHeader | Failure::SessionNotFound => StatusCode::UNAUTHORIZED,
        Failure::SessionDb | Failure::UserDb | Failure::NoRows | Failure::Db(_) => StatusCode::INTERNAL_SERVER_ERROR,
        Failure::Unique => StatusCode::CONFLICT,
        Failure::PlaylistNotYours | Failure::SongNotInLibrary | Failure::PositionNotThere { .. } => StatusCode::NOT_FOUND,
        Failure::PlaylistFull | Failure::QueueFull | Failure::QueueSource => StatusCode::BAD_REQUEST,
    };

    // The wording comes from `Display`, so the answer and the log line cannot disagree about
    // what happened. Only the database failure is named by the endpoint instead.
    let message = match err {
        Failure::NoRows | Failure::Db(_) => db_message.to_string(),
        other => other.to_string(),
    };

    error(status, &message)
}

/// `X-Content-Type-Options` is on every answer from this server, so it is added here rather
/// than at each call site.
fn build(status: StatusCode, headers: &[(&str, &str)], body: &[u8]) -> Response<Body> {
    let mut builder = Response::builder().status(status);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    builder
        .header("x-content-type-options", "nosniff")
        .body(Body::from(body.to_vec()))
        .expect("a response with a status and known header names")
}
