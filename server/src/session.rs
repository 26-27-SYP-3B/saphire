use axum::extract::{Request, State};
use axum::routing::get;
use axum::{http::StatusCode, response::Response, Router};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio_rusqlite::rusqlite;

use crate::{clock, db, hex, ratelimit, respond, respond::Failure, state::AppState, user};

/// How long a login stays valid. Short enough that a stolen token does not live forever,
/// long enough for a normal school day.
pub const SESSION_TTL_SECONDS: i64 = 24 * 60 * 60;

/// A row of the "session" table. The token itself is never stored, only its SHA-256 hash: a
/// leaked database must not hand out usable sessions. Lookups go through the hash as the
/// primary key, so there is no string-comparison timing signal either.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Session {
    #[serde(skip)]
    pub token_hash: String,
    #[serde(skip)]
    pub user_id: i64,
    pub created_at: i64,
    pub expires_at: i64,
}

pub fn ensure_table(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS session (
            token_hash TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL REFERENCES user(id),
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
        )",
        (),
    )?;
    Ok(())
}

/// Turns a raw token into its SHA-256 hex form, which is the primary key.
pub fn hash_token(token: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hex::hex(&hasher.finalize())
}

/// 32 bytes from the operating system's random source, as 64 hex characters. Not from a
/// seeded generator: tokens must not be predictable.
pub fn new_token() -> Result<String, Failure> {
    let mut buffer = [0u8; 32];
    getrandom::fill(&mut buffer).map_err(|error| Failure::Db(error.to_string()))?;
    Ok(hex::hex(&buffer))
}

pub fn insert(conn: &rusqlite::Connection, row: &Session) -> Result<(), Failure> {
    conn.execute(
        "INSERT INTO session (token_hash, user_id, created_at, expires_at) VALUES (?1, ?2, ?3, ?4)",
        (&row.token_hash, row.user_id, row.created_at, row.expires_at),
    )
    .map_err(db::failure)?;
    Ok(())
}

/// Looks a raw token up by its hash and drops the row when it is expired, so an expired
/// session never answers. A failure of the lookup itself is named as the session lookup,
/// because that is the message every protected endpoint gives for it.
pub fn find(conn: &rusqlite::Connection, token: &str) -> Result<Session, Failure> {
    let row = conn
        .query_row(
            "SELECT token_hash, user_id, created_at, expires_at FROM session WHERE token_hash = ?1",
            (hash_token(token),),
            |row| {
                Ok(Session {
                    token_hash: row.get(0)?,
                    user_id: row.get(1)?,
                    created_at: row.get(2)?,
                    expires_at: row.get(3)?,
                })
            },
        )
        .map_err(db::failure);

    let row = match row {
        Ok(row) => row,
        Err(Failure::NoRows) => return Err(Failure::SessionNotFound),
        Err(Failure::Db(_)) => return Err(Failure::SessionDb),
        Err(err) => return Err(err),
    };

    if clock::unix_now() > row.expires_at {
        conn.execute("DELETE FROM session WHERE token_hash = ?1", (&row.token_hash,))
            .map_err(db::failure)?;
        return Err(Failure::SessionNotFound);
    }

    Ok(row)
}

/// The raw token of `Authorization: Bearer <token>`, copied out as its own String.
///
/// Reading a header is deliberately a plain (non-async) call that hands back an owned value: a
/// request body may be moved between threads but not shared between them, so a borrow of the
/// request held across an `.await` would make the handler future non-`Send` and axum would
/// refuse the handler. This is the same rule the `Arc<Mutex<_>>` in `db` solves for the
/// connection.
pub fn bearer(req: &Request) -> Option<String> {
    let auth = req.headers().get("authorization")?.to_str().ok()?;
    Some(auth.strip_prefix("Bearer ")?.to_string())
}

/// Resolves a session token to the user the session belongs to. Every protected endpoint answers
/// with these same messages, so a client learns the same thing here as from the library or a
/// playlist.
pub async fn authenticate(database: &db::Db, token: &str) -> Result<user::User, Failure> {
    let token = token.to_string();
    let user_id = db::call(database, move |conn| match find(conn, &token) {
        Ok(row) => Ok(row.user_id),
        Err(err) => Err(err),
    })
    .await?;

    db::call(database, move |conn| match user::get_by_id(conn, user_id) {
        Ok(found) => Ok(found),
        // A valid token whose user is gone means the same thing to the caller as an expired
        // session, so it answers the same way.
        Err(Failure::NoRows) => Err(Failure::SessionNotFound),
        // The wording for a failed user lookup belongs to the session check, not to the
        // endpoint that called it.
        Err(Failure::Db(_)) => Err(Failure::UserDb),
        Err(err) => Err(err),
    })
    .await
}

/// The authenticated caller, or the answer this request gets when it is not one. Every
/// protected endpoint resolves the caller through here, so a missing header or an expired
/// session reads the same from the library, a playlist and the queue as from this endpoint.
///
/// The token comes in as its own value, never as a borrow of the request: a request body can be
/// moved between threads but not shared between them, so an async function that holds `&Request`
/// across an `.await` is not a `Send` future and axum refuses such a handler. Reading the header
/// is therefore a plain call, and only the copied token is carried into the async part.
// The error side is a whole Response, which clippy counts as large; boxing it would only add
// noise to a path that answers as it is.
#[allow(clippy::result_large_err)]
pub async fn caller(state: &AppState, token: Option<String>) -> Result<user::User, Response> {
    let token = match token {
        Some(token) => token,
        None => return Err(respond::answer(&Failure::MissingAuthHeader, "could not load session")),
    };

    authenticate(&state.db, &token)
        .await
        .map_err(|err| respond::answer(&err, "could not load session"))
}

pub async fn handle(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    match caller(&state, bearer(&req)).await {
        Ok(found) => respond::json(StatusCode::OK, &found),
        Err(response) => response,
    }
}

pub fn routes(state: AppState) -> Router {
    Router::new().route("/api/session", get(handle)).with_state(state)
}
