use axum::extract::{Path, Request, State};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{delete, get, post};
use axum::Router;
use serde::{Deserialize, Serialize};
use tokio_rusqlite::rusqlite;

use crate::{clock, db, jsonbody, pathvalue, ratelimit, respond, respond::Failure, sanitize, session, state::AppState};

/// Playlist limits. A name is capped so one answer stays readable, and the number of songs is
/// capped so one playlist cannot grow without bound. 200 songs is far more than a school
/// project needs; a client that wants more needs pagination (see api-docs.md, Upcoming).
pub const MAX_NAME_LEN: usize = 100;
pub const MAX_SONGS: i64 = 200;

/// A playlist belongs to the user who created it, unlike the library, which is shared — so
/// reading one is always "my playlists", and a playlist of another user reads as not existing.
/// Two playlists may have the same name: nothing in the table says they must differ.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Playlist {
    pub id: i64,
    #[serde(skip)]
    pub user_id: i64,
    pub name: String,
    pub created_at: i64,
    pub song_count: i64,
}

/// One row of `playlist_song`: a song at a position. A song can be in a playlist more than
/// once, at different positions, because a playlist is an order, not a set.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct PlaylistSong {
    pub position: i64,
    pub track_id: i64,
    pub title: String,
}

/// What `GET /api/playlists/{id}` answers. The list endpoint carries `song_count` only, so a
/// client that shows the playlists does not get every song of every playlist in one answer.
/// The fields of the playlist are written out rather than flattened, so the answer keeps the
/// order the client reads.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct PlaylistWithSongs {
    pub id: i64,
    pub name: String,
    pub created_at: i64,
    pub song_count: i64,
    pub songs: Vec<PlaylistSong>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlaylistRequest {
    pub name: String,
}

/// The JSON body of `POST /api/playlists/{id}/songs`, shared with `POST /api/queue/songs`:
/// `track_id` is a library id, so it is the same number the list endpoint shows.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SongRequest {
    pub track_id: i64,
}

/// Called from `db::open_db` so tests get the same schema as the server.
pub fn ensure_tables(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS playlist (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES user(id),
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )",
        (),
    )?;

    // position is the order inside the playlist. It is renumbered when a song is removed, so
    // the positions a client sees are always 1..n with no gaps. A song may appear at two
    // positions, so there is no UNIQUE on track_id.
    conn.execute(
        "CREATE TABLE IF NOT EXISTS playlist_song (
            playlist_id INTEGER NOT NULL REFERENCES playlist(id),
            track_id INTEGER NOT NULL REFERENCES track(id),
            position INTEGER NOT NULL,
            added_at INTEGER NOT NULL
        )",
        (),
    )?;
    Ok(())
}

/// Removes control characters, the same rule a title follows, and reports whether the name fits
/// the cap. A name that is too long is refused rather than cut: a playlist is named by the
/// person who made it, and a silently shorter name would be a different playlist than the one
/// they asked for — the same reason the 200 songs cap is a refusal and not a drop. Cleaning
/// with one character more than the cap is enough to see that the name is longer, and the
/// count is characters, not bytes.
pub fn clean_name(name: &str) -> Option<String> {
    let cleaned = sanitize::without_control_chars(name, MAX_NAME_LEN + 1);
    if cleaned.chars().count() > MAX_NAME_LEN {
        return None;
    }
    Some(cleaned)
}

/// Saves a playlist and fills in its id. The name is not unique: the same person may have two
/// playlists called "Favoriten", and they are different things.
pub fn create(conn: &rusqlite::Connection, user_id: i64, name: &str) -> Result<Playlist, Failure> {
    let now = clock::unix_now();
    conn.execute(
        "INSERT INTO playlist (user_id, name, created_at) VALUES (?1, ?2, ?3)",
        (user_id, name, now),
    )
    .map_err(db::failure)?;

    Ok(Playlist {
        id: conn.last_insert_rowid(),
        user_id,
        name: name.to_string(),
        created_at: now,
        song_count: 0,
    })
}

/// The caller's own playlists, ordered by id. `song_count` is a count, not the songs: the
/// songs come from `GET /api/playlists/{id}`. An empty list answers `[]`, not null, so a
/// client does not have to tell the two apart.
pub fn list(conn: &rusqlite::Connection, user_id: i64) -> Result<Vec<Playlist>, Failure> {
    let mut statement = conn
        .prepare(
            "SELECT p.id, p.name, p.created_at,
                (SELECT COUNT(*) FROM playlist_song WHERE playlist_id = p.id)
            FROM playlist p WHERE p.user_id = ?1 ORDER BY p.id",
        )
        .map_err(db::failure)?;

    let mut playlists = Vec::new();
    let rows = statement
        .query_map((user_id,), |row| {
            Ok(Playlist {
                id: row.get(0)?,
                user_id: 0,
                name: row.get(1)?,
                created_at: row.get(2)?,
                song_count: row.get(3)?,
            })
        })
        .map_err(db::failure)?;
    for row in rows {
        playlists.push(row.map_err(db::failure)?);
    }
    Ok(playlists)
}

/// Loads one playlist with its songs in order. The title comes from the library row: a
/// playlist stores references, not copies. An empty playlist answers `[]`, not null.
pub fn with_songs(conn: &rusqlite::Connection, user_id: i64, id: i64) -> Result<PlaylistWithSongs, Failure> {
    let base = get_for(conn, user_id, id)?;

    let mut statement = conn
        .prepare(
            "SELECT s.position, s.track_id, t.title
            FROM playlist_song s JOIN track t ON t.id = s.track_id
            WHERE s.playlist_id = ?1 ORDER BY s.position",
        )
        .map_err(db::failure)?;

    let mut songs = Vec::new();
    let rows = statement
        .query_map((base.id,), |row| {
            Ok(PlaylistSong {
                position: row.get(0)?,
                track_id: row.get(1)?,
                title: row.get(2)?,
            })
        })
        .map_err(db::failure)?;
    for row in rows {
        songs.push(row.map_err(db::failure)?);
    }

    Ok(PlaylistWithSongs {
        id: base.id,
        name: base.name,
        created_at: base.created_at,
        song_count: base.song_count,
        songs,
    })
}

/// Loads one playlist without its songs. A playlist of another user is not found, so this is
/// also the ownership check every write below depends on.
pub fn get_for(conn: &rusqlite::Connection, user_id: i64, id: i64) -> Result<Playlist, Failure> {
    // The name a caller means is their own playlist, so a missing row here is not "no row"
    // but the playlist answer. This is the ownership check every write below depends on.
    let mut playlist = match conn
        .query_row(
            "SELECT id, name, created_at FROM playlist WHERE id = ?1 AND user_id = ?2",
            (id, user_id),
            |row| {
                Ok(Playlist {
                    id: row.get(0)?,
                    user_id: 0,
                    name: row.get(1)?,
                    created_at: row.get(2)?,
                    song_count: 0,
                })
            },
        )
        .map_err(db::failure)
    {
        Ok(playlist) => playlist,
        Err(Failure::NoRows) => return Err(Failure::PlaylistNotYours),
        Err(err) => return Err(err),
    };
    let count = conn
        .query_row(
            "SELECT COUNT(*) FROM playlist_song WHERE playlist_id = ?1",
            (playlist.id,),
            |row| row.get::<_, i64>(0),
        )
        .map_err(db::failure)?;
    playlist.song_count = count;

    Ok(playlist)
}

/// Puts one song at the end of a playlist and returns the position it got. Running inside one
/// transaction is what makes the count and the insert one uninterrupted piece of work, so two
/// callers cannot be handed the same position.
pub fn add_song(conn: &rusqlite::Connection, user_id: i64, playlist_id: i64, track_id: i64) -> Result<PlaylistSong, Failure> {
    let playlist = match get_for(conn, user_id, playlist_id) {
        Ok(playlist) => playlist,
        Err(Failure::NoRows) => return Err(Failure::PlaylistNotYours),
        Err(err) => return Err(err),
    };
    if playlist.song_count >= MAX_SONGS {
        return Err(Failure::PlaylistFull);
    }

    let title = match conn
        .query_row("SELECT title FROM track WHERE id = ?1", (track_id,), |row| row.get::<_, String>(0))
        .map_err(db::failure)
    {
        Ok(title) => title,
        Err(Failure::NoRows) => return Err(Failure::SongNotInLibrary),
        Err(err) => return Err(err),
    };

    let position = playlist.song_count + 1;
    conn.execute(
        "INSERT INTO playlist_song (playlist_id, track_id, position, added_at) VALUES (?1, ?2, ?3, ?4)",
        (playlist_id, track_id, position, clock::unix_now()),
    )
    .map_err(db::failure)?;

    Ok(PlaylistSong {
        position,
        track_id,
        title,
    })
}

/// Takes one position out of a playlist and renumbers the songs after it, so the positions a
/// client sees stay 1..n with no gaps.
pub fn remove_song(conn: &rusqlite::Connection, user_id: i64, playlist_id: i64, position: i64) -> Result<(), Failure> {
    match get_for(conn, user_id, playlist_id) {
        Ok(_) => {}
        Err(Failure::NoRows) => return Err(Failure::PlaylistNotYours),
        Err(err) => return Err(err),
    }

    let removed = conn
        .execute(
            "DELETE FROM playlist_song WHERE playlist_id = ?1 AND position = ?2",
            (playlist_id, position),
        )
        .map_err(db::failure)?;
    if removed == 0 {
        return Err(Failure::PositionNotThere {
            container: "playlist",
            position,
        });
    }

    conn.execute(
        "UPDATE playlist_song SET position = position - 1 WHERE playlist_id = ?1 AND position > ?2",
        (playlist_id, position),
    )
    .map_err(db::failure)?;
    Ok(())
}

/// Removes a playlist and its songs. The songs themselves stay in the shared library: a
/// playlist is a list of references, not a copy of the file.
pub fn delete_playlist(conn: &rusqlite::Connection, user_id: i64, id: i64) -> Result<(), Failure> {
    match get_for(conn, user_id, id) {
        Ok(_) => {}
        Err(Failure::NoRows) => return Err(Failure::PlaylistNotYours),
        Err(err) => return Err(err),
    }

    conn.execute("DELETE FROM playlist_song WHERE playlist_id = ?1", (id,))
        .map_err(db::failure)?;
    conn.execute("DELETE FROM playlist WHERE id = ?1", (id,)).map_err(db::failure)?;
    Ok(())
}

async fn handle_create(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let body = match jsonbody::read_object::<PlaylistRequest>(req.into_body(), "\"name\"").await {
        Ok(body) => body,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let name = match clean_name(&body.name) {
        Some(name) => name,
        None => {
            return respond::error(
                StatusCode::BAD_REQUEST,
                &format!("a playlist name is at most {} characters", MAX_NAME_LEN),
            )
        }
    };
    if name.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "the playlist needs a name");
    }

    match db::call(&state.db, move |conn| create(conn, caller.id, &name)).await {
        Ok(playlist) => respond::json(StatusCode::CREATED, &playlist),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_list(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    match db::call(&state.db, move |conn| list(conn, caller.id)).await {
        Ok(playlists) => respond::json(StatusCode::OK, &playlists),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_get(State(state): State<AppState>, id: Path<String>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let id = match pathvalue::parse_positive(&id.0, "playlist id") {
        Ok(id) => id,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    match db::call(&state.db, move |conn| with_songs(conn, caller.id, id)).await {
        Ok(playlist) => respond::json(StatusCode::OK, &playlist),
        Err(err) => respond::answer(&err, db_message()),
    }
}

/// The song is added at the end, and the answer says which position it got.
async fn handle_add_song(State(state): State<AppState>, id: Path<String>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let id = match pathvalue::parse_positive(&id.0, "playlist id") {
        Ok(id) => id,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let body = match jsonbody::read_object::<SongRequest>(req.into_body(), "\"track_id\"").await {
        Ok(body) => body,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };
    if body.track_id <= 0 {
        return respond::error(StatusCode::BAD_REQUEST, "track_id must be a positive number");
    }

    // Counting and inserting belong to one transaction, so they see the same state.
    let added = db::call(&state.db, move |conn| {
        let tx = conn.transaction().map_err(db::failure)?;
        let song = add_song(&tx, caller.id, id, body.track_id)?;
        tx.commit().map_err(db::failure)?;
        Ok(song)
    })
    .await;

    match added {
        Ok(song) => respond::json(StatusCode::CREATED, &song),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_remove_song(State(state): State<AppState>, ids: Path<(String, String)>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let id = match pathvalue::parse_positive(&ids.0 .0, "playlist id") {
        Ok(id) => id,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };
    let position = match pathvalue::parse_positive(&ids.0 .1, "position") {
        Ok(position) => position,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let removed = db::call(&state.db, move |conn| {
        let tx = conn.transaction().map_err(db::failure)?;
        remove_song(&tx, caller.id, id, position)?;
        tx.commit().map_err(db::failure)?;
        Ok(())
    })
    .await;

    match removed {
        Ok(()) => respond::no_content(),
        Err(err) => respond::answer(&err, db_message()),
    }
}

async fn handle_delete(State(state): State<AppState>, id: Path<String>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    let caller = match session::caller(&state, session::bearer(&req)).await {
        Ok(caller) => caller,
        Err(response) => return response,
    };

    let id = match pathvalue::parse_positive(&id.0, "playlist id") {
        Ok(id) => id,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let deleted = db::call(&state.db, move |conn| {
        let tx = conn.transaction().map_err(db::failure)?;
        delete_playlist(&tx, caller.id, id)?;
        tx.commit().map_err(db::failure)?;
        Ok(())
    })
    .await;

    match deleted {
        Ok(()) => respond::no_content(),
        Err(err) => respond::answer(&err, db_message()),
    }
}

/// What a playlist endpoint calls a database failure. Only the reasons named in `respond` are
/// answered by name; anything else stays unnamed.
fn db_message() -> &'static str {
    "the playlist could not be read"
}

pub fn routes(state: AppState) -> Router {
    Router::new()
        .route("/api/playlists", post(handle_create).get(handle_list))
        .route("/api/playlists/{id}", get(handle_get).delete(handle_delete))
        .route("/api/playlists/{id}/songs", post(handle_add_song))
        .route("/api/playlists/{id}/songs/{position}", delete(handle_remove_song))
        .with_state(state)
}
