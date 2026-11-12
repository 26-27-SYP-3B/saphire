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
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_rusqlite::rusqlite;

use crate::{clock, db, hex, metadata, pathvalue, ratelimit, respond, respond::Failure, sanitize, session, state::AppState};

/// Upload limits. The body limit covers the multipart framing plus the file: a single song
/// must not be able to fill the disk.
pub const MAX_UPLOAD_BYTES: usize = 500 << 20;
pub const MAX_TITLE_LEN: usize = 200;

/// How much of a file goes out at a time. Small enough that a player starts playing before
/// the whole file is read, large enough that a 500 MiB song is not sent in tiny pieces.
pub const CHUNK_BYTES: usize = 32 << 10;

/// The audio formats whose extension alone names their content type, for the files whose bytes
/// say nothing (most containers have no signature the sniffer can read). Any other audio file is
/// still accepted — see `detect_audio_type`.
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
///
/// `artist` and `duration_ms` are what the file itself said (see `metadata`). A file that does
/// not say them stays empty or zero, and the client shows a dash. Field order is the order
/// `api-docs.md` documents, so the answer and the documentation read the same.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct Track {
    pub id: i64,
    #[serde(skip)]
    pub user_id: i64,
    pub uploaded_by: String,
    pub title: String,
    pub artist: String,
    pub duration_ms: i64,
    pub stored_name: String,
    pub size: i64,
    pub content_type: String,
    pub uploaded_at: i64,
}

/// The columns a track is read with, in the order `scan_track` expects. The uploader is joined
/// from the user table because the library answer shows a name, not a bare id.
const TRACK_COLUMNS: &str = "track.id, track.user_id, track.title, track.artist, track.duration_ms, \
    track.stored_name, track.size, track.content_type, track.uploaded_at, user.username";

/// Reads one row into a track. A single lookup and a list both use this, so they cannot
/// disagree about what a row contains.
fn scan_track(row: &rusqlite::Row<'_>) -> rusqlite::Result<Track> {
    Ok(Track {
        id: row.get(0)?,
        user_id: row.get(1)?,
        title: row.get(2)?,
        artist: row.get(3)?,
        duration_ms: row.get(4)?,
        stored_name: row.get(5)?,
        size: row.get(6)?,
        content_type: row.get(7)?,
        uploaded_at: row.get(8)?,
        uploaded_by: row.get(9)?,
    })
}

pub fn ensure_table(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS track (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL REFERENCES user(id),
            title TEXT NOT NULL,
            artist TEXT NOT NULL DEFAULT '',
            duration_ms INTEGER NOT NULL DEFAULT 0,
            stored_name TEXT UNIQUE NOT NULL,
            size INTEGER NOT NULL,
            content_type TEXT NOT NULL,
            uploaded_at INTEGER NOT NULL
        )",
        (),
    )?;
    ensure_columns(conn)
}

/// Adds the metadata columns to a table that was created before they existed: `CREATE TABLE IF
/// NOT EXISTS` never changes a table that is already there, so an existing `saphire.db` needs
/// each missing column on its own. Existing rows get the default, which is what an untagged
/// file has anyway.
///
/// The column names here are fixed literals, not user input, so building the statement is safe
/// even though every other query in this server is parameterized. `ALTER TABLE` has no
/// `IF NOT EXISTS`, so only the columns that are missing are added.
pub fn ensure_columns(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    let mut statement = conn.prepare("PRAGMA table_info(track)")?;
    let names = statement.query_map((), |row| row.get::<_, String>(1))?;

    let mut have: Vec<String> = Vec::new();
    for name in names {
        have.push(name?);
    }

    for (name, definition) in [
        ("artist", "artist TEXT NOT NULL DEFAULT ''"),
        ("duration_ms", "duration_ms INTEGER NOT NULL DEFAULT 0"),
    ] {
        if have.iter().any(|column| column == name) {
            continue;
        }
        conn.execute(&format!("ALTER TABLE track ADD COLUMN {definition}"), ())?;
    }

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
        "INSERT INTO track (user_id, title, artist, duration_ms, stored_name, size, content_type, uploaded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        (
            track.user_id,
            &track.title,
            &track.artist,
            track.duration_ms,
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
        &format!("SELECT {TRACK_COLUMNS} FROM track JOIN user ON user.id = track.user_id WHERE track.id = ?1"),
        (id,),
        scan_track,
    )
    .map_err(db::failure)
}

/// The whole library ordered by id, as one full row per song. The library is shared, so the
/// list shows who added a song and what the file said about itself; a row without tags reads as
/// an empty artist and a length of 0, which the client shows as a dash rather than a guess.
/// An empty library answers as an empty list, not as nothing, so a client does not have to tell
/// the two apart.
pub fn list(conn: &rusqlite::Connection) -> Result<Vec<Track>, Failure> {
    let mut statement = conn
        .prepare(&format!("SELECT {TRACK_COLUMNS} FROM track JOIN user ON user.id = track.user_id ORDER BY track.id"))
        .map_err(db::failure)?;

    let rows = statement.query_map((), scan_track).map_err(db::failure)?;

    let mut tracks = Vec::new();
    for row in rows {
        tracks.push(row.map_err(db::failure)?);
    }
    Ok(tracks)
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

/// What an uploaded file is.
///
/// Every audio file is accepted, not only the containers listed in `AUDIO_EXTENSIONS`: there are
/// more formats than a table can keep up with (AIFF, WMA, AMR, MIDI, …), and a song refused for
/// its extension is a song the person cannot upload.
///
/// The bytes still decide what they can. A file whose content is provably not audio — text, an
/// image, a PDF, an archive — is refused under any name, and a content type the sniffer names wins
/// over the extension. When the bytes are just binary, the extension is taken at its word: the
/// listed formats get their documented type, everything else is served as `audio/<extension>`.
pub fn detect_audio_type(extension: &str, data: &[u8]) -> Result<String, String> {
    let sniffed = normalize_audio_type(&sniff(data));

    if is_audio(&sniffed) {
        return Ok(sniffed);
    }
    if sniffed != "application/octet-stream" {
        return Err(format!("the uploaded file is not audio, its content reads as {sniffed}"));
    }

    if let Some((_, media_type)) = AUDIO_EXTENSIONS.iter().find(|(ext, _)| *ext == extension) {
        return Ok((*media_type).to_string());
    }
    // The extension becomes the content type of a stored row, so only one that can be a media
    // subtype is taken: a name like `Lied.äöü` or `track.` cannot be, and a header built from it
    // would fail on every later stream of that song.
    match audio_subtype(extension) {
        Some(subtype) => Ok(format!("audio/{subtype}")),
        None => Err("the uploaded file has no extension that says what it is".to_string()),
    }
}

/// The subtype of a client extension, when it can be one: ASCII letters and digits, at most ten.
fn audio_subtype(extension: &str) -> Option<&str> {
    let subtype = extension.trim_start_matches('.');
    let usable = !subtype.is_empty() && subtype.len() <= 10 && subtype.bytes().all(|byte| byte.is_ascii_alphanumeric());
    usable.then_some(subtype)
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
    const SIGNATURES: [(&[u8], &str); 14] = [
        (b"RIFF", "audio/wave"),
        (b"ID3", "audio/mpeg"),
        (b"ID2", "audio/mpeg"),
        (b"Ogg", "audio/ogg"),
        (b"\x89PNG\r\n\x1a\n", "image/png"),
        (b"\xff\xd8\xff", "image/jpeg"),
        (b"GIF8", "image/gif"),
        (b"%PDF", "application/pdf"),
        (b"PK\x03\x04", "application/zip"),
        (b"\x1f\x8b", "application/gzip"),
        (b"\x7fELF", "application/x-elf"),
        (b"MZ", "application/x-msdownload"),
        (b"Rar!", "application/vnd.rar"),
        (b"7z\xbc\xaf", "application/x-7z-compressed"),
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

    // The base name only: a name like `Album.2024/track` would otherwise make the extension
    // `.2024/track`, and the stored name would carry a folder separator.
    let extension = extension_of(&base_name(&file_name));
    let media_type = match detect_audio_type(&extension, &data) {
        Ok(media_type) => media_type,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    // The artist and the playing time come from the file itself. They are read before anything
    // is stored, so the row and the answer show the same values. Only MP3 has a length that can
    // be worked out from the bytes; the other containers keep 0, which the client shows as a dash.
    let meta = if media_type == "audio/mpeg" {
        metadata::read_audio_meta(&data)
    } else {
        metadata::AudioMeta::default()
    };

    // The title is what the file names itself when its tags do, otherwise the name the client
    // sent.
    let title = if meta.title.is_empty() {
        sanitize_title(&file_name)
    } else {
        meta.title.clone()
    };
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
        artist: meta.artist,
        duration_ms: meta.duration_ms,
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
    let file_info = match tokio::fs::metadata(&target).await {
        Ok(file_info) => file_info,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            // The file is written before the row, so this should not happen; it is a broken
            // library, and the client needs to know the song cannot be played.
            return respond::error(StatusCode::NOT_FOUND, "the file for this song is not in the library folder");
        }
        Err(_) => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not read the file"),
    };

    // Everything that can still be answered with the JSON error shape is decided here: after
    // the status line the status is fixed, and a later failure can only end the body.
    let mut file = match tokio::fs::File::open(&target).await {
        Ok(file) => file,
        Err(_) => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not read the file"),
    };

    let size = file_info.len() as i64;
    let range = req
        .headers()
        .get("range")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();

    // The part that is sent, as an inclusive range. An empty file has no part, so its
    // `Content-Length` is 0 rather than a length that cannot be sent.
    let mut from = 0i64;
    let mut to = size - 1;
    if !range.is_empty() {
        let Some((start, end)) = parse_byte_range(&range, size) else {
            // A range that cannot be read as bytes, or one outside the file, is answered as
            // plain text: the caller here is a player, and this error is about the transport,
            // not about the API. It still names the size the caller asked about.
            let content_range = format!("bytes */{size}");
            return respond::plain_text(
                StatusCode::RANGE_NOT_SATISFIABLE,
                &[("content-range", content_range.as_str())],
                "invalid range",
            );
        };
        from = start;
        to = end;
    }

    if from > 0 && file.seek(std::io::SeekFrom::Start(from as u64)).await.is_err() {
        return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not read the file");
    }

    // The stored name is what the file is called inside the library folder, and it is what the
    // upload answer reported, so a player that saved the row can name the file it is fetching.
    let disposition = format!("inline; filename=\"{}\"", base_name(&track.stored_name));
    let content_range = format!("bytes {from}-{to}/{size}");
    let part = to - from + 1;
    let content_length = part.to_string();

    let mut headers = vec![
        ("content-type", track.content_type.as_str()),
        ("accept-ranges", "bytes"),
        ("content-disposition", disposition.as_str()),
        ("content-length", content_length.as_str()),
    ];
    if !range.is_empty() {
        headers.push(("content-range", content_range.as_str()));
    }

    // A player that asked for part of the file gets 206, even for a range that starts at the
    // beginning of the file, because the answer describes a part and not the whole song.
    let status = if from > 0 || !range.is_empty() {
        StatusCode::PARTIAL_CONTENT
    } else {
        StatusCode::OK
    };

    respond::with_body(status, &headers, Body::from_stream(chunk_stream(file, part as u64)))
}

/// Reads one `bytes=<from>-<to>` range for a file of the given size and says whether it can be
/// served. A range that names nothing inside the file is not satisfiable, and a range with two
/// parts (`bytes=0-10,20-30`) is not read here: an audio player sends one range. An open end
/// (`bytes=900-`) means the rest of the file, and a leading dash (`bytes=-500`) means the last
/// 500 bytes. A start past the last byte, a suffix larger than the file, or an end past the last
/// byte is refused rather than clamped, as `api-docs.md` documents; a range that ends at the last
/// byte is the whole file and is served.
pub fn parse_byte_range(header: &str, size: i64) -> Option<(i64, i64)> {
    let value = header.strip_prefix("bytes=")?;
    if value.is_empty() || value.contains(',') || size == 0 {
        return None;
    }

    let (from_text, to_text) = match value.split_once('-') {
        Some((start, end)) => (start, end),
        // No dash is not a byte range an audio player can send.
        None => return None,
    };

    if from_text.is_empty() {
        // bytes=-<n>: the last n bytes
        let count = to_text.parse::<i64>().ok()?;
        if count <= 0 || count > size {
            return None;
        }
        return Some((size - count, size - 1));
    }

    let start = from_text.parse::<i64>().ok()?;
    if start < 0 || start >= size {
        return None;
    }

    // An open end means the rest of the file.
    if to_text.is_empty() {
        return Some((start, size - 1));
    }

    let end = to_text.parse::<i64>().ok()?;
    if end < 0 || end >= size || start > end {
        return None;
    }
    Some((start, end))
}

/// Reads the file piece by piece, at most `remaining` bytes of it. Each piece is written as its
/// own frame, which is what a flush was in the Go version: a player gets the start of a song
/// before the rest of the file is read, and a 500 MiB song is never held in memory as a whole.
pub fn chunk_stream(file: tokio::fs::File, remaining: u64) -> impl Stream<Item = Result<Bytes, io::Error>> + Send + 'static {
    stream::unfold((file, remaining), move |(mut file, remaining)| async move {
        if remaining == 0 {
            return None;
        }
        let want = remaining.min(CHUNK_BYTES as u64) as usize;
        let mut buffer = vec![0u8; want];
        match file.read(&mut buffer).await {
            Ok(0) => None,
            Ok(read) => Some((Ok(Bytes::copy_from_slice(&buffer[..read])), (file, remaining - read as u64))),
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
