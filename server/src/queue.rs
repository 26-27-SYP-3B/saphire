use axum::extract::{Path, Request, State};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{delete, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use tokio_rusqlite::rusqlite;

use crate::{clock, db, jsonbody, pathvalue, playlist, ratelimit, respond, respond::Failure, session, state::AppState};

/// Bounds one queue. A queue is read on every change, so an uncapped one would make one
/// answer as large as the whole library. 200 is far above what a player needs at one time.
pub const MAX_ENTRIES: i64 = 200;

/// One row of `queue_entry`: a song at a position in one user's queue. The queue stores only
/// the order and the songs. It does not store what filled it, because a queue must be fillable
/// from anything: a playlist today, search results or a single song later. That is what makes a
/// plain queue feature a UI job later, not a redesign here.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct QueueEntry {
    pub position: i64,
    pub track_id: i64,
    pub title: String,
}

/// The JSON body of `POST /api/queue`: which source fills the queue. `source_id` is needed for
/// a playlist or a single song; for the whole library the source alone is enough, so sending it
/// there is refused rather than ignored. It is an `Option` so that "not sent" and "sent as 0"
/// are different things — a plain `i64` cannot tell them apart, and 0 would look like a field
/// that was never sent.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QueueRequest {
    pub source: String,
    pub source_id: Option<i64>,
}

/// The places a queue can be filled from. Adding one later means one branch in `song_ids`;
/// nothing else about a queue changes.
pub fn is_source(source: &str) -> bool {
    matches!(source, "playlist" | "library" | "track")
}

pub fn source_message() -> &'static str {
    "source must be \"playlist\", \"library\" or \"track\""
}

/// Called from `db::open_db` so tests get the same schema as the server.
pub fn ensure_table(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS queue_entry (
            user_id INTEGER NOT NULL REFERENCES user(id),
            position INTEGER NOT NULL,
            track_id INTEGER NOT NULL REFERENCES track(id),
            added_at INTEGER NOT NULL
        )",
        (),
    )?;
    Ok(())
}

/// Resolves a source into the library ids a queue would be filled with, in the order the
/// source gives. This is the universal part: every source becomes an ordered list of song ids,
/// and filling a queue is the same work after that.
pub fn song_ids(conn: &rusqlite::Connection, user_id: i64, source: &str, source_id: i64) -> Result<Vec<i64>, Failure> {
    match source {
        "track" => {
            // A single song is a source like any other, and an unknown one is answered as the
            // missing song it is — not as an empty queue, which would quietly wipe the queue.
            let id = match conn
                .query_row("SELECT id FROM track WHERE id = ?1", (source_id,), |row| row.get::<_, i64>(0))
                .map_err(db::failure)
            {
                Ok(id) => id,
                Err(Failure::NoRows) => return Err(Failure::SongNotInLibrary),
                Err(err) => return Err(err),
            };
            Ok(vec![id])
        }
        "playlist" => {
            // Only the caller's own playlist can fill a queue, the same rule as reading it.
            let owned = conn
                .query_row(
                    "SELECT 1 FROM playlist WHERE id = ?1 AND user_id = ?2",
                    (source_id, user_id),
                    |row| row.get::<_, i64>(0),
                )
                .map_err(db::failure);
            match owned {
                Ok(_) => {}
                Err(Failure::NoRows) => return Err(Failure::PlaylistNotYours),
                Err(err) => return Err(err),
            }

            // The limit is read as part of the query, so a source larger than a queue is not
            // materialised in memory just to be refused.
            ids(
                conn,
                &format!(
                    "SELECT track_id FROM playlist_song WHERE playlist_id = ?1 ORDER BY position LIMIT {}",
                    MAX_ENTRIES + 1
                ),
                Some(source_id),
            )
        }
        "library" => ids(
            conn,
            &format!("SELECT id FROM track ORDER BY id LIMIT {}", MAX_ENTRIES + 1),
            None,
        ),
        // The handler checks the source before resolving it, so this arm is only reached if a
        // caller forgets that check; it still answers as the source error, not as a database
        // failure.
        _ => Err(Failure::QueueSource),
    }
}

fn ids(conn: &rusqlite::Connection, query: &str, param: Option<i64>) -> Result<Vec<i64>, Failure> {
    let mut statement = conn.prepare(query).map_err(db::failure)?;

    let to_id = |row: &rusqlite::Row| -> rusqlite::Result<i64> { row.get(0) };
    let rows = match param {
        Some(value) => statement.query_map((value,), to_id),
        None => statement.query_map((), to_id),
    }
    .map_err(db::failure)?;

    let mut ids = Vec::new();
    for row in rows {
        ids.push(row.map_err(db::failure)?);
    }

    if ids.len() as i64 > MAX_ENTRIES {
        return Err(Failure::QueueFull);
    }
    // An empty source fills an empty queue: that is what a playlist with no songs means, and
    // the client already shows an empty queue. It is not an error.
    Ok(ids)
}

/// One user's queue in order. An empty queue answers `[]`, not null.
pub fn entries(conn: &rusqlite::Connection, user_id: i64) -> Result<Vec<QueueEntry>, Failure> {
    let mut statement = conn
        .prepare(
            "SELECT q.position, q.track_id, t.title
            FROM queue_entry q JOIN track t ON t.id = q.track_id
            WHERE q.user_id = ?1 ORDER BY q.position",
        )
        .map_err(db::failure)?;

    let mut entries = Vec::new();
    let rows = statement
        .query_map((user_id,), |row| {
            Ok(QueueEntry {
                position: row.get(0)?,
                track_id: row.get(1)?,
                title: row.get(2)?,
            })
        })
        .map_err(db::failure)?;
    for row in rows {
        entries.push(row.map_err(db::failure)?);
    }
    Ok(entries)
}

/// Adds one song at the end of a queue and returns the position it got. This is the plain
/// queue feature: fill a queue from a source, or add one song.
pub fn append(conn: &rusqlite::Connection, user_id: i64, track_id: i64) -> Result<QueueEntry, Failure> {
    let count = conn
        .query_row("SELECT COUNT(*) FROM queue_entry WHERE user_id = ?1", (user_id,), |row| row.get::<_, i64>(0))
        .map_err(db::failure)?;
    if count >= MAX_ENTRIES {
        return Err(Failure::QueueFull);
    }

    let title = match conn
        .query_row("SELECT title FROM track WHERE id = ?1", (track_id,), |row| row.get::<_, String>(0))
        .map_err(db::failure)
    {
        Ok(title) => title,
        Err(Failure::NoRows) => return Err(Failure::SongNotInLibrary),
        Err(err) => return Err(err),
    };

    let position = count + 1;
    insert_row(conn, user_id, position, track_id, clock::unix_now())?;

    Ok(QueueEntry {
        position,
        track_id,
        title,
    })
}

/// Takes one position out of a queue and renumbers the songs after it, so the positions a
/// client sees stay 1..n with no gaps.
pub fn remove(conn: &rusqlite::Connection, user_id: i64, position: i64) -> Result<(), Failure> {
    let removed = conn
        .execute("DELETE FROM queue_entry WHERE user_id = ?1 AND position = ?2", (user_id, position))
        .map_err(db::failure)?;
    if removed == 0 {
        return Err(Failure::PositionNotThere {
            container: "queue",
            position,
        });
    }

    conn.execute(
        "UPDATE queue_entry SET position = position - 1 WHERE user_id = ?1 AND position > ?2",
        (user_id, position),
    )
    .map_err(db::failure)?;
    Ok(())
}

/// Empties a queue. The songs stay in the library.
pub fn clear(conn: &rusqlite::Connection, user_id: i64) -> Result<(), Failure> {
    conn.execute("DELETE FROM queue_entry WHERE user_id = ?1", (user_id,))
        .map_err(db::failure)?;
    Ok(())
}

fn insert_row(conn: &rusqlite::Connection, user_id: i64, position: i64, track_id: i64, added_at: i64) -> Result<(), Failure> {
    conn.execute(
        "INSERT INTO queue_entry (user_id, position, track_id, added_at) VALUES (?1, ?2, ?3, ?4)",
        (user_id, position, track_id, added_at),
    )
    .map_err(db::failure)?;
    Ok(())
}

/// Replaces a queue with the songs of one source, in the order that source gives.
pub fn fill(conn: &rusqlite::Connection, user_id: i64, source: &str, source_id: i64) -> Result<(), Failure> {
    let ids = song_ids(conn, user_id, source, source_id)?;

    conn.execute("DELETE FROM queue_entry WHERE user_id = ?1", (user_id,))
        .map_err(db::failure)?;

    let now = clock::unix_now();
    for (index, id) in ids.iter().enumerate() {
        insert_row(conn, user_id, index as i64 + 1, *id, now)?;
    }
    Ok(())
}

async fn handle_fill(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let body = match jsonbody::read_object::<QueueRequest>(req.into_body(), "\"source\"").await {
        Ok(body) => body,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    if !is_source(&body.source) {
        return respond::error(StatusCode::BAD_REQUEST, source_message());
    }
    if body.source == "library" && body.source_id.is_some() {
        // The whole library names nothing, so a source_id there is not ignored: it is refused,
        // because the caller meant something else.
        return respond::error(StatusCode::BAD_REQUEST, "source_id is not used for the whole library");
    }
    // A source that names something needs a real id. "Not sent" and "sent as 0" are different
    // things here, and both are refused the same way.
    if body.source != "library" {
        match body.source_id {
            Some(id) if id > 0 => {}
            _ => return respond::error(StatusCode::BAD_REQUEST, "source_id must be a positive number"),
        }
    }

    let source = body.source.clone();
    let source_id = body.source_id.unwrap_or(0);

    // Deleting and inserting happen in one transaction, so a queue is never seen as the old
    // source with the new one partly added. What the client is shown is the committed state, so
    // the read happens after the commit.
    let filled = db::call(&state.db, move |conn| {
        let tx = conn.transaction().map_err(db::failure)?;
        fill(&tx, caller.id, &source, source_id)?;
        tx.commit().map_err(db::failure)?;
        entries(conn, caller.id)
    })
    .await;

    match filled {
        Ok(entries) => respond::json(StatusCode::OK, &entries),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_get(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    match db::call(&state.db, move |conn| entries(conn, caller.id)).await {
        Ok(entries) => respond::json(StatusCode::OK, &entries),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_append(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let body = match jsonbody::read_object::<playlist::SongRequest>(req.into_body(), "\"track_id\"").await {
        Ok(body) => body,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };
    if body.track_id <= 0 {
        return respond::error(StatusCode::BAD_REQUEST, "track_id must be a positive number");
    }

    let track_id = body.track_id;
    let added = db::call(&state.db, move |conn| {
        let tx = conn.transaction().map_err(db::failure)?;
        let entry = append(&tx, caller.id, track_id)?;
        tx.commit().map_err(db::failure)?;
        Ok(entry)
    })
    .await;

    match added {
        Ok(entry) => respond::json(StatusCode::CREATED, &entry),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_remove(State(state): State<AppState>, position: Path<String>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let position = match pathvalue::parse_positive(&position.0, "position") {
        Ok(position) => position,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let removed = db::call(&state.db, move |conn| {
        let tx = conn.transaction().map_err(db::failure)?;
        remove(&tx, caller.id, position)?;
        tx.commit().map_err(db::failure)?;
        Ok(())
    })
    .await;

    match removed {
        Ok(()) => respond::no_content(),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_clear(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    match db::call(&state.db, move |conn| clear(conn, caller.id)).await {
        Ok(()) => respond::no_content(),
        Err(err) => respond::answer(&err, db_message()),
    }
}

/// What a queue endpoint calls a database failure. Only the reasons named in `respond` are
/// answered by name; anything else stays unnamed.
fn db_message() -> &'static str {
    "the queue could not be read"
}

pub fn routes(state: AppState) -> Router {
    Router::new()
        .route("/api/queue", post(handle_fill).get(handle_get).delete(handle_clear))
        .route("/api/queue/songs", post(handle_append))
        .route("/api/queue/{position}", delete(handle_remove))
        .with_state(state)
    }
