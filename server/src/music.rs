use std::io;

use axum::body::{Body, Bytes};
use axum::extract::{Path, Request, State};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::{get, post};
use axum::Router;
use futures_util::stream::{self, Stream, TryStreamExt};
use http_body_util::{BodyExt, Limited};
use serde::{Deserialize, Serialize};
use tokio::io::AsyncReadExt;
use tokio_rusqlite::rusqlite;

use crate::{clock, db, hex, pathvalue, ratelimit, respond, respond::Failure, sanitize, session, state::AppState};

/// Upload limits. The body limit covers the multipart framing plus the file: a single song
/// must not be able to fill the disk.
pub const MAX_UPLOAD_BYTES: usize = 500 << 20;
pub const MAX_TITLE_LEN: usize = 200;

/// How much of a file goes out at a time. Small enough that a player starts playing before
/// the whole file is read, large enough that a 500 MiB song is not sent in tiny pieces.
pub const CHUNK_BYTES: usize = 32 << 10;

/// The formats the library accepts, with the content type they are reported as.
///
/// Not every audio container can be sniffed (M4A reads as plain binary), so the extension
/// decides those cases; for the formats the sniffer can name, the bytes must actually agree
/// with it.
pub const AUDIO_EXTENSIONS: [(&str, &str); 7] = [
    (".mp3", "audio/mpeg"),
    (".wav", "audio/wav"),
    (".m4a", "audio/mp4"),
    (".ogg", "audio/ogg"),
    (".opus", "audio/ogg"),
    (".flac", "audio/flac"),
    (".aac", "audio/aac"),
];

/// A row of the "track" table: one song in the shared library. The library folder belongs to
/// the server, not to a user, so a row stores who uploaded it and under which name the file
/// lives. `uploaded_by` is not a column; it is filled for the answer so the shared library
/// shows a name instead of a bare user id.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub id: i64,
    #[serde(skip)]
    pub user_id: i64,
    pub uploaded_by: String,
    pub title: String,
    pub stored_name: String,
    pub size: i64,
    pub content_type: String,
    pub uploaded_at: i64,
}

/// What `GET /api/music` shows for one song: the two fields a client needs to list the
/// library, and nothing else. The name the file has inside the library folder stays on the
/// server.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct LibraryEntry {
    pub id: i64,
    pub title: String,
}

pub fn ensure_table(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS track (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES user(id),
            title TEXT NOT NULL,
            stored_name TEXT UNIQUE NOT NULL,
            size INTEGER NOT NULL,
            content_type TEXT NOT NULL,
            uploaded_at INTEGER NOT NULL
        )",
        (),
    )?;
    Ok(())
}

/// Creates the shared music library folder and returns its path. Every uploaded song is saved
/// there, so the library is the same for all users.
pub fn library_path() -> String {
    match std::env::var("SAPHIRE_LIBRARY_PATH") {
        Ok(path) if !path.is_empty() => path,
        _ => "library".to_string(),
    }
}

/// Creates the folder songs are stored in. The folder is taken as an argument so a test can
/// check that it is created without changing the environment of the whole process.
pub fn open_library_in(dir: &str) -> Result<String, Failure> {
    std::fs::create_dir_all(dir).map_err(|error| Failure::Db(error.to_string()))?;
    Ok(dir.to_string())
}

pub fn open_library() -> Result<String, Failure> {
    open_library_in(&library_path())
}

pub fn insert(conn: &rusqlite::Connection, track: &mut Track) -> Result<(), Failure> {
    conn.execute(
        "INSERT INTO track (user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        (
            track.user_id,
            &track.title,
            &track.stored_name,
            track.size,
            &track.content_type,
            track.uploaded_at,
        ),
    )
    .map_err(db::failure)?;

    track.id = conn.last_insert_rowid();
    Ok(())
}

pub fn get_by_id(conn: &rusqlite::Connection, id: i64) -> Result<Track, Failure> {
    conn.query_row(
        "SELECT id, user_id, title, stored_name, size, content_type, uploaded_at FROM track WHERE id = ?1",
        (id,),
        |row| {
            Ok(Track {
                id: row.get(0)?,
                user_id: row.get(1)?,
                uploaded_by: String::new(),
                title: row.get(2)?,
                stored_name: row.get(3)?,
                size: row.get(4)?,
                content_type: row.get(5)?,
                uploaded_at: row.get(6)?,
            })
        },
    )
    .map_err(db::failure)
}

/// The whole library ordered by id. An empty library answers as an empty list, not as nothing,
/// so a client does not have to tell the two apart.
pub fn list(conn: &rusqlite::Connection) -> Result<Vec<LibraryEntry>, Failure> {
    let mut statement = conn
        .prepare("SELECT id, title FROM track ORDER BY id")
        .map_err(db::failure)?;

    let mut entries = Vec::new();
    let rows = statement
        .query_map((), |row| Ok(LibraryEntry { id: row.get(0)?, title: row.get(1)? }))
        .map_err(db::failure)?;
    for row in rows {
        entries.push(row.map_err(db::failure)?);
    }
    Ok(entries)
}

/// Turns an uploaded name into a name inside the library. It is generated here from random
/// bytes, so a client name like `../evil.mp3` cannot escape the library folder or overwrite
/// another user's file — the shared library has no per-user path.
pub fn stored_file_name(extension: &str) -> Result<String, Failure> {
    let mut buffer = [0u8; 16];
    getrandom::fill(&mut buffer).map_err(|error| Failure::Db(error.to_string()))?;
    Ok(hex::hex(&buffer) + extension)
}

/// The base name of an uploaded file, so a name cannot climb out of the library folder.
pub fn base_name(name: &str) -> String {
    name.rsplit('/').next().unwrap_or(name).to_string()
}

pub fn sanitize_title(name: &str) -> String {
    sanitize::without_control_chars(&base_name(name), MAX_TITLE_LEN)
}

pub fn extension_of(name: &str) -> String {
    match name.rfind('.') {
        Some(dot) => name[dot..].to_lowercase(),
        None => String::new(),
    }
}

/// What an uploaded file is. The extension must be an allowed audio format, and the bytes must
/// agree with it where they can be sniffed. Formats the sniffer cannot name read as plain
/// binary and are accepted on their extension alone; a text file or an image renamed `.mp3` is
/// refused.
pub fn detect_audio_type(extension: &str, data: &[u8]) -> Result<String, String> {
    let by_extension = match AUDIO_EXTENSIONS.iter().find(|(ext, _)| *ext == extension) {
        Some((_, media_type)) => *media_type,
        None => return Err("only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)".to_string()),
    };

    let sniffed = normalize_audio_type(&sniff(data));
    if sniffed == "application/octet-stream" {
        return Ok(by_extension.to_string());
    }
    if !is_audio(&sniffed) {
        return Err(format!("the uploaded file is not audio, its content reads as {sniffed}"));
    }
    Ok(sniffed)
}

/// The sniffer reports WAV as `audio/wave` and Ogg as `application/ogg`. Both are audio, and
/// both are stored under the name this server uses for that format, so one format always has
/// one name.
fn normalize_audio_type(media_type: &str) -> String {
    match media_type {
        "audio/wave" => "audio/wav".to_string(),
        "application/ogg" => "audio/ogg".to_string(),
        other => other.to_string(),
    }
}

fn is_audio(media_type: &str) -> bool {
    media_type.starts_with("audio/")
}

/// The signatures the sniffer can name, reduced to what this endpoint needs: text, the audio
/// containers it recognizes, and the formats a file renamed `.mp3` turns out to be. Unknown
/// bytes answer as plain binary, which is what lets an extension decide.
fn sniff(data: &[u8]) -> String {
    const SIGNATURES: [(&[u8], &str); 8] = [
        (b"RIFF", "audio/wave"),
        (b"ID3", "audio/mpeg"),
        (b"ID2", "audio/mpeg"),
        (b"Ogg", "audio/ogg"),
        (b"\x89PNG\r\n\x1a\n", "image/png"),
        (b"\xff\xd8\xff", "image/jpeg"),
        (b"GIF8", "image/gif"),
        (b"%PDF", "application/pdf"),
    ];

    for (signature, media_type) in SIGNATURES {
        if data.len() >= signature.len() && &data[..signature.len()] == signature {
            return media_type.to_string();
        }
    }

    if data.iter().all(|byte| byte.is_ascii_graphic() || byte.is_ascii_whitespace()) {
        return "text/plain; charset=utf-8".to_string();
    }

    "application/octet-stream".to_string()
}

pub async fn handle_upload(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many uploads from this address, try again later", retry);
    }

    // Auth before the body is read, so an anonymous caller cannot make the server read
    // 500 MiB it will throw away.
    let uploader = match session::caller(&state, session::bearer(&req)).await {
        Ok(uploader) => uploader,
        Err(response) => return response,
    };

    let content_type = req
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();

    if !content_type.starts_with("multipart/form-data") {
        return respond::error(StatusCode::BAD_REQUEST, "body must be a multipart/form-data request with a \"file\" field");
    }

    let boundary = match multer::parse_boundary(&content_type) {
        Ok(boundary) => boundary,
        Err(_) => {
            return respond::error(StatusCode::BAD_REQUEST, "body must be a multipart/form-data request with a \"file\" field")
        }
    };

    // The limit covers the framing plus the file, so it is checked while reading.
    let collected = match Limited::new(req.into_body(), MAX_UPLOAD_BYTES + 1).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(_) => return respond::error(StatusCode::PAYLOAD_TOO_LARGE, "upload is larger than 500 MiB"),
    };

    let body = stream::once(async move { Ok::<_, multer::Error>(collected) });
    let mut multipart = multer::Multipart::new(body, boundary);

    let field = match multipart.next_field().await {
        Ok(Some(field)) => field,
        Ok(None) => return respond::error(StatusCode::BAD_REQUEST, "no file was uploaded"),
        Err(_) => return respond::error(StatusCode::BAD_REQUEST, "the upload could not be read"),
    };

    if field.name() != Some("file") || field.file_name().is_none() {
        return respond::error(StatusCode::BAD_REQUEST, "the file must be sent in a form field named \"file\"");
    }

    let file_name = field.file_name().unwrap_or_default().to_string();
    let data = match field.try_collect::<Vec<_>>().await {
        Ok(chunks) => chunks.concat(),
        Err(_) => return respond::error(StatusCode::BAD_REQUEST, "the upload could not be read"),
    };

    if data.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "the uploaded file is empty");
    }

    let extension = extension_of(&file_name);
    let media_type = match detect_audio_type(&extension, &data) {
        Ok(media_type) => media_type,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let title = sanitize_title(&file_name);
    if title.is_empty() {
        return respond::error(StatusCode::BAD_REQUEST, "the uploaded file has no usable name");
    }

    let stored = match stored_file_name(&extension) {
        Ok(stored) => stored,
        Err(err) => return respond::answer(&err, "could not name the file"),
    };

    // The file first, then the row: writing the row first could leave a library entry pointing
    // at a file that is not there. If the insert fails, the file is removed again so nothing
    // is left half-saved.
    let target = std::path::Path::new(&state.library).join(&stored);
    if tokio::fs::write(&target, &data).await.is_err() {
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not save the file");
    }

    let mut track = Track {
        id: 0,
        user_id: uploader.id,
        uploaded_by: uploader.username,
        title,
        stored_name: stored,
        size: data.len() as i64,
        content_type: media_type,
        uploaded_at: clock::unix_now(),
    };

    // The row is written through `db::call`, so the id the insert fills in comes back with the
    // row; the answer is the row that was actually stored.
    let saved = db::call(&state.db, move |conn| {
        insert(conn, &mut track)?;
        Ok(track)
    })
    .await;

    match saved {
        Ok(saved) => respond::json(StatusCode::CREATED, &saved),
        Err(err) => {
            // The file was written before the row, so a failed insert leaves a file nothing
            // points at; removing it keeps the library folder and the table in agreement.
            let _ = tokio::fs::remove_file(&target).await;
            respond::answer(&err, "could not save the upload")
        }
    }
}


pub async fn handle_list(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    if let Err(response) = session::caller(&state, session::bearer(&req)).await {
        return response;
    }

    match db::call(&state.db, |conn| list(conn)).await {
        Ok(entries) => respond::json(StatusCode::OK, &entries),
        Err(err) => respond::answer(&err, "could not list the library"),
    }
}

pub async fn handle_stream(State(state): State<AppState>, id: Path<String>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many requests from this address, try again later", retry);
    }

    // Auth before the file is opened, as in the upload endpoint: an anonymous caller must not
    // make the server read a whole song it will not send.
    if let Err(response) = session::caller(&state, session::bearer(&req)).await {
        return response;
    }

    let id = match pathvalue::parse_positive(&id.0, "song id") {
        Ok(id) => id,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let track = match db::call(&state.db, move |conn| get_by_id(conn, id)).await {
        Ok(track) => track,
        Err(Failure::NoRows) => return respond::error(StatusCode::NOT_FOUND, "song is not in the library"),
        Err(err) => return respond::answer(&err, "could not load the song"),
    };

    // The stored name is generated here, so it cannot name anything outside the library folder.
    let target = std::path::Path::new(&state.library).join(&track.stored_name);
    let metadata = match tokio::fs::metadata(&target).await {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            // The file is written before the row, so this should not happen; it is a broken
            // library, and the client needs to know the song cannot be played.
            return respond::error(StatusCode::NOT_FOUND, "the file for this song is not in the library folder");
        }
        Err(_) => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not read the file"),
    };

    // Everything that can still be answered with the JSON error shape is decided here: after
    // the status line the status is fixed, and a later failure can only end the body.
    let file = match tokio::fs::File::open(&target).await {
        Ok(file) => file,
        Err(_) => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not read the file"),
    };

    // Content-Length is the size of the file that is actually sent, so a player can show
    // progress. It does not change how the body is written: the pieces still go out one by one.
    let length = metadata.len().to_string();
    respond::with_body(
        StatusCode::OK,
        &[("content-type", track.content_type.as_str()), ("content-length", length.as_str())],
        Body::from_stream(chunk_stream(file)),
    )
}

/// Reads the file piece by piece. Each piece is written as its own frame, which is what a
/// flush was in the Go version: a player gets the start of a song before the rest of the file
/// is read, and a 500 MiB song is never held in memory as a whole.
pub fn chunk_stream(file: tokio::fs::File) -> impl Stream<Item = Result<Bytes, io::Error>> + Send + 'static {
    stream::unfold(file, move |mut file| async move {
        let mut buffer = vec![0u8; CHUNK_BYTES];
        match file.read(&mut buffer).await {
            Ok(0) => None,
            Ok(read) => Some((Ok(Bytes::copy_from_slice(&buffer[..read])), file)),
            // A read error after the status line cannot become a JSON error, so the body
            // simply stops here.
            Err(_) => None,
        }
    })
}

pub fn list_routes(state: AppState) -> Router {
    Router::new().route("/api/music", get(handle_list)).with_state(state)
}

pub fn stream_routes(state: AppState) -> Router {
    Router::new().route("/api/music/{id}", get(handle_stream)).with_state(state)
}

pub fn upload_routes(state: AppState) -> Router {
    Router::new().route("/api/music/upload", post(handle_upload)).with_state(state)
}
