mod common;

use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::extract::{ConnectInfo, Request};
use axum::http::{HeaderMap, StatusCode};
use http_body_util::BodyExt;
use saphire_server::{app, clock, db, music, ratelimit, user};
use tower::ServiceExt;

/// A real WAV header with enough padding to span several stream chunks.
fn big_wav() -> Vec<u8> {
    let mut big = common::tiny_wav();
    big.extend_from_slice(&vec![0u8; 3 * music::CHUNK_BYTES]);
    big
}

/// One GET read piece by piece. `common::call` collects the whole body into a string, so it
/// cannot show the delivery in pieces that this endpoint exists for.
struct Stream {
    status: StatusCode,
    headers: HeaderMap,
    body: Vec<u8>,
    /// Bytes that arrived with each piece, in the order they arrived.
    pieces: Vec<usize>,
}

async fn read_stream(test: &common::Test, path: &str, token: &str) -> Stream {
    let mut builder = Request::builder().method("GET").uri(path);
    if !token.is_empty() {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }

    // The same peer the other helpers use, so the request is measured against its own bucket.
    let mut request = builder.body(Body::empty()).expect("build the request");
    request.extensions_mut().insert(ConnectInfo(common::peer()));

    let response = test.app.clone().oneshot(request).await.expect("send the request");
    let (parts, mut body) = response.into_parts();

    let mut pieces = Vec::new();
    let mut content = Vec::new();
    while let Some(frame) = body.frame().await {
        let frame = frame.expect("read the frame");
        if let Ok(data) = frame.into_data() {
            pieces.push(data.len());
            content.extend_from_slice(&data);
        }
    }

    Stream {
        status: parts.status,
        headers: parts.headers,
        body: content,
        pieces,
    }
}

fn header_value(headers: &HeaderMap, name: &str) -> String {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string()
}

/// The server creates the folder it saves songs in. The folder is passed as an argument, so
/// this does not change the environment of the whole process.
#[tokio::test]
async fn open_library_creates_the_library_folder() {
    let temp = tempfile::TempDir::new().expect("create the test library");
    let dir = temp.path().join("library").to_string_lossy().to_string();

    let opened = music::open_library_in(&dir).expect("open library");
    assert_eq!(opened, dir, "open_library_in must answer with the folder it uses");

    let info = std::fs::metadata(&opened).expect("the library folder must exist");
    assert!(info.is_dir(), "{opened} is not a folder");

    // A second call on an existing folder is fine, the server starts repeatedly.
    music::open_library_in(&opened).expect("open the library again");
}

/// The rule this endpoint exists for: nobody who is not logged in may put anything into the
/// shared library.
#[tokio::test]
async fn upload_requires_auth() {
    let test = common::setup().await;

    let reply = common::upload(&test, "", "file", "song.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "anonymous upload -> {} ({})", reply.status, reply.body);
    assert!(
        reply.body.contains("authorization header"),
        "missing header must use the missing-header message: {}",
        reply.body
    );

    let reply = common::upload(&test, "not-a-known-token", "file", "song.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "unknown token -> {} ({})", reply.status, reply.body);
    assert!(
        reply.body.contains("session is not valid or expired"),
        "unknown token must use the session message: {}",
        reply.body
    );

    // Nothing was stored for the refused requests.
    let entries: Vec<_> = std::fs::read_dir(&test.library).expect("read the library").collect();
    assert!(entries.is_empty(), "a refused upload wrote a file: {entries:?}");
    assert_eq!(common::count(&test, "track").await, 0, "a refused upload saved a track row");
}

#[tokio::test]
async fn upload_saves_to_the_shared_library() {
    let test = common::setup().await;
    let lukas = common::token(&test, "lukas", "valid-password").await;

    let reply = common::upload(&test, &lukas, "file", "mein lied.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    let id = track["id"].as_i64().unwrap_or(0);
    assert!(id > 0, "answer has no id: {}", reply.body);
    assert_eq!(track["title"].as_str(), Some("mein lied.wav"), "answer is incomplete: {}", reply.body);
    assert_eq!(track["uploaded_by"].as_str(), Some("lukas"), "answer is incomplete: {}", reply.body);
    assert_eq!(track["size"].as_i64(), Some(common::tiny_wav().len() as i64), "wrong size: {}", reply.body);
    assert_eq!(track["content_type"].as_str(), Some("audio/wav"), "wrong content type: {}", reply.body);

    // The file is in the shared library folder under the generated name.
    let stored = track["stored_name"].as_str().expect("the answer has a stored_name").to_string();
    let saved = std::fs::read(test.library.join(&stored)).expect("the song is not in the library folder");
    assert_eq!(saved, common::tiny_wav(), "the saved file does not match what was uploaded");

    // The library is shared: another user reads the same track and the same file.
    let seen = common::run(&test, move |conn| music::get_by_id(conn, id)).await;
    assert_eq!(seen.stored_name, stored, "the row does not point at the file in the library");
    assert!(seen.user_id > 0, "the track does not record who uploaded it");

    // The same title from someone else is a second file, never an overwrite.
    let nina = common::token(&test, "nina", "valid-password").await;
    let reply = common::upload(&test, &nina, "file", "mein lied.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "second upload -> {} ({})", reply.status, reply.body);

    let other = common::json(&reply.body);
    assert_ne!(
        other["stored_name"].as_str(),
        Some(stored.as_str()),
        "the second upload overwrote the first file: {}",
        reply.body
    );
    assert_eq!(other["uploaded_by"].as_str(), Some("nina"), "the second upload is not attributed to its uploader: {}", reply.body);
}

/// The input rules: only real audio, never empty, never over the size limit, always in the
/// "file" field.
#[tokio::test]
async fn upload_rejects_bad_uploads() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let cases = [
        ("plain text named like audio", "file", "notes.txt", b"just text".to_vec(), StatusCode::BAD_REQUEST),
        ("plain text renamed .mp3", "file", "notes.mp3", b"just text".to_vec(), StatusCode::BAD_REQUEST),
        (
            "an image named like audio",
            "file",
            "cover.mp3",
            b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR".to_vec(),
            StatusCode::BAD_REQUEST,
        ),
        ("extension not allowed", "file", "song.zip", common::not_audio(), StatusCode::BAD_REQUEST),
        ("empty file", "file", "empty.wav", Vec::new(), StatusCode::BAD_REQUEST),
        ("field is not a file", "file", "", common::not_audio(), StatusCode::BAD_REQUEST),
        ("wrong field name", "upload", "song.flac", common::not_audio(), StatusCode::BAD_REQUEST),
        ("no file at all", "", "", Vec::new(), StatusCode::BAD_REQUEST),
        (
            "larger than 500 MiB",
            "file",
            "big.wav",
            vec![0u8; music::MAX_UPLOAD_BYTES + 1],
            StatusCode::PAYLOAD_TOO_LARGE,
        ),
    ];

    for (name, field, file, content, want) in cases {
        let reply = common::upload(&test, &token, field, file, &content).await;
        assert_eq!(reply.status, want, "{name} -> {} ({})", reply.status, reply.body);
    }

    // A request that is not multipart at all is refused before anything is read. `common::call`
    // passes header values verbatim, so the Bearer prefix has to be written out here.
    let auth = format!("Bearer {token}");
    let reply = common::call(&test, "POST", "/api/music/upload", b"not multipart", &[("authorization", auth.as_str())]).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "not multipart -> {} ({})", reply.status, reply.body);

    // A client name that tries to climb out of the folder is stored inside it.
    let reply = common::upload(&test, &token, "file", "../escape.flac", &common::not_audio()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload with ../ in the name -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    let stored = track["stored_name"].as_str().expect("the answer has a stored_name").to_string();
    assert!(!stored.contains('/'), "stored name is not a plain library file name: {stored}");
    assert_eq!(track["title"].as_str(), Some("escape.flac"), "title was not reduced to the base name: {}", reply.body);
    assert_eq!(
        track["content_type"].as_str(),
        Some("audio/flac"),
        "an unsniffable audio container is stored with its extension type, got {:?}",
        track["content_type"].as_str()
    );

    let info = std::fs::metadata(test.library.join(&stored)).expect("the file is not inside the library folder");
    assert!(info.is_file(), "the file is not inside the library folder: {stored}");
}

/// What the Go version refused: its sniffer reported `application/ogg`, which is not an
/// `audio/` type, so a real Ogg file was refused even though `.ogg` is an allowed extension.
/// This server keeps one name per format, so the sniffed Ogg is stored as `audio/ogg`, which is
/// what `api-docs.md` documents.
#[tokio::test]
async fn an_ogg_file_is_accepted_as_audio() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let ogg = b"OggS\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".to_vec();
    let reply = common::upload(&test, &token, "file", "song.ogg", &ogg).await;
    assert_eq!(reply.status, StatusCode::CREATED, "ogg upload -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    assert_eq!(track["content_type"].as_str(), Some("audio/ogg"), "Ogg is not stored as the documented type: {}", reply.body);
}

#[tokio::test]
async fn upload_is_rate_limited_per_address() {
    // A wide refill window on purpose: with a one second window the tokens between two requests
    // would depend on how fast this machine reads a 500 MiB body. A long window makes the test
    // measure the limit, not the machine.
    let mut limiters = app::test_limiters();
    limiters.upload = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&limiters).await;
    let token = common::token(&test, "lukas", "valid-password").await;

    for upload in 1..=2 {
        let reply = common::upload(&test, &token, "file", "song.wav", &common::tiny_wav()).await;
        assert_eq!(reply.status, StatusCode::CREATED, "upload {upload} -> {} ({})", reply.status, reply.body);
    }

    let reply = common::upload(&test, &token, "file", "song.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third upload -> {} ({})", reply.status, reply.body);
    common::check_retry_after(&reply, 60);

    // The upload bucket is its own: a full bucket answers before the token is looked up, so a
    // flood of anonymous uploads cannot starve the session checks.
    let reply = common::upload(&test, "", "file", "song.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "upload bucket must be separate -> {} ({})", reply.status, reply.body);
}

/// Reading the shared library needs an account, with the same two 401 messages as
/// `GET /api/session`.
#[tokio::test]
async fn list_requires_auth() {
    let test = common::setup().await;

    let reply = common::get(&test, "/api/music", "").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "anonymous list -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("authorization header"), "missing header must use the missing-header message: {}", reply.body);

    let reply = common::get(&test, "/api/music", "not-a-known-token").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "unknown token -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("session is not valid or expired"), "unknown token must use the session message: {}", reply.body);
}

#[tokio::test]
async fn list_answers_id_and_title_ordered_by_id() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    // An empty library answers [], not null.
    let reply = common::get(&test, "/api/music", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "list -> {} ({})", reply.status, reply.body);
    assert_eq!(reply.body.trim(), "[]", "empty library answered {}, wanted []", reply.body);

    // Rows are inserted out of insertion order. This cannot prove the sort: for INTEGER PRIMARY
    // KEY the id is the rowid, so a plain scan already returns rows in id order. It is tested
    // because ORDER BY id is what the answer promises, and the promise must hold if the schema
    // ever changes.
    let user = common::run(&test, move |conn| user::get_by_username(conn, "lukas")).await;
    let now = clock::unix_now();
    for id in [5, 2] {
        common::run(&test, move |conn| {
            conn.execute(
                "INSERT INTO track (id, user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                (id, user.id, format!("song-{id}.wav"), format!("file-{id}.wav"), 1, "audio/wav", now),
            )
            .map_err(db::failure)?;
            Ok(())
        })
        .await;
    }

    let reply = common::get(&test, "/api/music", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "list -> {} ({})", reply.status, reply.body);

    let entries = common::json(&reply.body).as_array().expect("the answer is a list").clone();
    assert_eq!(entries.len(), 2, "list has {} entries, wanted 2 ({})", entries.len(), reply.body);
    assert_eq!(entries[0]["id"].as_i64(), Some(2), "the list is not ordered by id: {}", reply.body);
    assert_eq!(entries[1]["id"].as_i64(), Some(5), "the list is not ordered by id: {}", reply.body);
    assert_eq!(entries[0]["title"].as_str(), Some("song-2.wav"), "the titles do not match the ids: {}", reply.body);
    assert_eq!(entries[1]["title"].as_str(), Some("song-5.wav"), "the titles do not match the ids: {}", reply.body);

    // id and title only: the name the file has inside the library folder stays on the server.
    for entry in &entries {
        let object = entry.as_object().expect("an entry is an object");
        assert_eq!(object.len(), 2, "an entry carries more than id and title: {entry}");
    }
}

/// The point of this endpoint: the file goes out piece by piece, so a player gets the beginning
/// of a song before the rest is read.
#[tokio::test]
async fn stream_sends_the_file_in_pieces() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let big = big_wav();
    let reply = common::upload(&test, &token, "file", "song.wav", &big).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    let id = track["id"].as_i64().expect("the answer has an id");

    let stream = read_stream(&test, &format!("/api/music/{id}"), &token).await;
    assert_eq!(stream.status, StatusCode::OK, "stream -> {}", stream.status);

    assert_eq!(header_value(&stream.headers, "content-type"), "audio/wav", "the stored content type must be the response content type");
    assert_eq!(
        header_value(&stream.headers, "content-length"),
        big.len().to_string(),
        "Content-Length {}, wanted {}",
        header_value(&stream.headers, "content-length"),
        big.len()
    );
    assert_eq!(
        header_value(&stream.headers, "x-content-type-options"),
        "nosniff",
        "the stream answer must carry nosniff like every other answer: {:?}",
        stream.headers
    );
    assert_eq!(stream.body, big, "streamed {} bytes, wanted {}", stream.body.len(), big.len());

    // The body must arrive as several pieces, each no larger than the chunk size, and the first
    // piece must be smaller than the whole file. The Go test measured the length present at each
    // flush; here the piece sizes are read directly, which is the same statement.
    assert!(stream.pieces.len() >= 2, "the body was sent in {} piece(s), not in chunks", stream.pieces.len());
    for (number, size) in stream.pieces.iter().enumerate() {
        assert!(*size > 0, "piece {number} added no bytes: {:?}", stream.pieces);
        assert!(
            *size <= music::CHUNK_BYTES,
            "piece {} sent {} bytes, more than the {} byte chunk size",
            number + 1,
            size,
            music::CHUNK_BYTES
        );
    }
    assert!(stream.pieces[0] < big.len(), "the whole file was sent at once, so nothing was streamed");

    // A file smaller than one chunk is still one piece, not zero.
    let small = common::upload(&test, &token, "file", "small.wav", &common::tiny_wav()).await;
    assert_eq!(small.status, StatusCode::CREATED, "small upload -> {} ({})", small.status, small.body);

    let small_json = common::json(&small.body);
    let small_id = small_json["id"].as_i64().expect("the answer has an id");

    let small_stream = read_stream(&test, &format!("/api/music/{small_id}"), &token).await;
    assert_eq!(small_stream.pieces.len(), 1, "a small file was sent in {} piece(s), wanted one", small_stream.pieces.len());
}

/// The answers before the first byte, which are the only ones that can still use the JSON error
/// shape.
#[tokio::test]
async fn stream_rejects_bad_requests() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let reply = common::upload(&test, &token, "file", "song.wav", &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    let id = track["id"].as_i64().expect("the answer has an id");
    let stored = track["stored_name"].as_str().expect("the answer has a stored_name").to_string();

    let cases = [
        ("no header", "/api/music/1", "", StatusCode::UNAUTHORIZED, "authorization header"),
        ("unknown token", "/api/music/1", "not-a-known-token", StatusCode::UNAUTHORIZED, "session is not valid or expired"),
        ("id is not a number", "/api/music/abc", token.as_str(), StatusCode::BAD_REQUEST, "the song id must be a positive number"),
        ("id is negative", "/api/music/-1", token.as_str(), StatusCode::BAD_REQUEST, "the song id must be a positive number"),
        ("id is zero", "/api/music/0", token.as_str(), StatusCode::BAD_REQUEST, "the song id must be a positive number"),
        ("id has leading zeros", "/api/music/0004", token.as_str(), StatusCode::BAD_REQUEST, "the song id must be a positive number"),
        ("id has a plus sign", "/api/music/+4", token.as_str(), StatusCode::BAD_REQUEST, "the song id must be a positive number"),
        ("id is digits but too large", "/api/music/9223372036854775808", token.as_str(), StatusCode::BAD_REQUEST, "the song id is too large"),
        ("id is not in the library", "/api/music/999", token.as_str(), StatusCode::NOT_FOUND, "song is not in the library"),
    ];

    for (name, path, caller, want, message) in cases {
        let reply = common::get(&test, path, caller).await;
        assert_eq!(reply.status, want, "{name} -> {} ({}), wanted {} with {message:?}", reply.status, reply.body, want);
        assert!(reply.body.contains(message), "{name} -> {} ({}), wanted the message {message:?}", reply.status, reply.body);
    }

    // A row whose file is gone is a broken library: the song is listed but cannot be played, and
    // the answer must say which.
    std::fs::remove_file(test.library.join(&stored)).expect("remove the file");
    let reply = common::get(&test, &format!("/api/music/{id}"), &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "row with a missing file -> {} ({})", reply.status, reply.body);
    assert!(
        reply.body.contains("is not in the library folder"),
        "row with a missing file -> {}, wanted 404 naming the missing file ({})",
        reply.status,
        reply.body
    );
}

/// The two read buckets are separate: a client that polls the list cannot starve playback, and a
/// player that opens several songs cannot starve the list. A shared instance would fail here, so
/// each direction needs its own wiring.
#[tokio::test]
async fn stream_and_list_have_their_own_buckets() {
    // A wide refill window on purpose: reading a file and hashing a token take noticeable time,
    // so with a one second window the tokens between two requests would depend on how fast this
    // machine is. A long window makes the test measure the limit, not the machine.
    let mut stream_full = app::test_limiters();
    stream_full.stream = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&stream_full).await;
    let token = common::token(&test, "lukas", "valid-password").await;

    // A full stream bucket must not stop the list.
    for request in 1..=2 {
        let reply = common::get(&test, "/api/music/1", &token).await;
        assert_eq!(reply.status, StatusCode::NOT_FOUND, "stream {request} -> {}, wanted the 404 for an empty library ({})", reply.status, reply.body);
    }

    let reply = common::get(&test, "/api/music/1", &token).await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third stream -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("too many requests from this address"), "third stream -> {} ({})", reply.status, reply.body);
    common::check_retry_after(&reply, 60);

    let reply = common::get(&test, "/api/music", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "a full stream bucket stopped the list -> {} ({})", reply.status, reply.body);

    // The other way round: a full list bucket must not stop playback.
    let mut list_full = app::test_limiters();
    list_full.library = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&list_full).await;
    let token = common::token(&test, "lukas", "valid-password").await;

    for request in 1..=3 {
        let reply = common::get(&test, "/api/music", &token).await;
        if request < 3 {
            assert_eq!(reply.status, StatusCode::OK, "list {request} -> {} ({})", reply.status, reply.body);
        } else {
            assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third list -> {} ({})", reply.status, reply.body);
        }
    }

    let reply = common::get(&test, "/api/music/1", &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "a full list bucket stopped playback -> {} ({})", reply.status, reply.body);
}
