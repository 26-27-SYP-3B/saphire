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

// The MP3 fixtures are built by hand, the same way tests/metadata.rs builds them, so the numbers
// this test states are its own and not what the code under test calculated. MPEG 1, Layer III,
// bitrate index 9 = 128 kbps, sample index 2 = 32000 Hz: a frame is 144 * 128000 / 32000 = 576
// bytes and 1152 / 32000 s = 36 ms long, so ten frames are 360 ms.
fn mp3_frame_header(version: u32, layer: u32, bitrate_index: u32, sample_index: u32, padding: u32) -> [u8; 4] {
    let mut head: u32 = 0xFFE0_0000;
    head |= version << 19;
    head |= layer << 17;
    head |= 1 << 16; // no CRC
    head |= bitrate_index << 12;
    head |= sample_index << 10;
    head |= padding << 9;
    head.to_be_bytes()
}

fn syncsafe_bytes(value: usize) -> [u8; 4] {
    [
        ((value >> 21) & 0x7f) as u8,
        ((value >> 14) & 0x7f) as u8,
        ((value >> 7) & 0x7f) as u8,
        (value & 0x7f) as u8,
    ]
}

fn text_frame(encoding: u8, text: &str) -> Vec<u8> {
    let mut payload = vec![encoding];
    payload.extend_from_slice(text.as_bytes());
    payload
}

/// An ID3v2.3 tag, whose frame sizes are plain numbers. The reader has to tell this apart from the
/// syncsafe sizes of ID3v2.4, so the fixture is written the way a tagged file is written.
fn build_id3_tag(frames: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut body = Vec::new();
    for (id, payload) in frames {
        body.extend_from_slice(id.as_bytes());
        body.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        body.extend_from_slice(&[0, 0]); // frame flags
        body.extend_from_slice(payload);
    }

    let mut tag = vec![b'I', b'D', b'3', 3, 0, 0];
    tag.extend_from_slice(&syncsafe_bytes(body.len()));
    tag.extend_from_slice(&body);
    tag
}

fn audio_of(count: usize) -> Vec<u8> {
    let mut data = Vec::new();
    for _ in 0..count {
        data.extend_from_slice(&mp3_frame_header(3, 1, 9, 2, 0));
        data.extend_from_slice(&[0u8; 572]);
    }
    data
}

/// A whole MP3 an upload can send: a tag that names a title and an artist, and ten frames.
fn tagged_mp3() -> Vec<u8> {
    let tag = build_id3_tag(&[("TIT2", text_frame(0, "Neutrone (Remix)")), ("TPE1", text_frame(0, "Kraftwerk"))]);
    [tag, audio_of(10)].concat()
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

/// One GET with a `Range` header. The body has to be read as bytes, because a range of a binary
/// file is compared against the file itself and `common::call` turns a body into a String.
async fn read_range(test: &common::Test, path: &str, token: &str, range: &str) -> Stream {
    let mut builder = Request::builder().method("GET").uri(path);
    if !token.is_empty() {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    builder = builder.header("range", range);

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

/// The fields `api-docs.md` documents for a track, in the documented order. `user_id` is not one
/// of them, so the two ways of reading a row can only be compared on the fields that are answered.
fn documented(track: &music::Track) -> (i64, &str, &str, &str, i64, &str, i64, &str, i64) {
    (
        track.id,
        &track.uploaded_by,
        &track.title,
        &track.artist,
        track.duration_ms,
        &track.stored_name,
        track.size,
        &track.content_type,
        track.uploaded_at,
    )
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

/// What the endpoint does with what a file says about itself. The title is what the file names
/// itself when its tags do; the name the client sent is the fallback, not the fallback for a file
/// that has tags. The values are read before anything is stored, so the answer and the row must
/// show the same ones.
#[tokio::test]
async fn upload_titles_a_file_by_its_tags_and_falls_back_to_the_name() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let reply = common::upload(&test, &token, "file", "Mein Song.mp3", &tagged_mp3()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "tagged upload -> {} ({})", reply.status, reply.body);

    let tagged = common::decode::<music::Track>(&reply.body);
    assert_eq!(tagged.title, "Neutrone (Remix)", "the answer does not show what the file says: {}", reply.body);
    assert_eq!(tagged.artist, "Kraftwerk", "the answer does not show what the file says: {}", reply.body);
    // Ten frames of 1152 samples at 32000 Hz.
    assert_eq!(tagged.duration_ms, 10 * 1152 * 1000 / 32000, "the answer does not show the length the frames give: {}", reply.body);

    // The row holds the same values the answer shows.
    let stored = common::run(&test, move |conn| music::get_by_id(conn, tagged.id)).await;
    assert_eq!(documented(&stored), documented(&tagged), "the row does not hold what the answer shows: {stored:?}");

    // An untagged file is measured but not named, so the name the client sent stays the title and
    // the artist stays empty. The same name is sent so the two paths are compared with each other
    // and not with two different files.
    let reply = common::upload(&test, &token, "file", "Mein Song.mp3", &audio_of(10)).await;
    assert_eq!(reply.status, StatusCode::CREATED, "untagged upload -> {} ({})", reply.status, reply.body);

    let plain = common::decode::<music::Track>(&reply.body);
    assert_eq!(plain.title, "Mein Song.mp3", "an untagged file is not titled by the name it was sent with: {}", reply.body);
    assert_eq!(plain.artist, "", "a file that does not name an artist must not report one: {}", reply.body);
    assert_eq!(plain.duration_ms, 10 * 1152 * 1000 / 32000, "an untagged file is not measured: {}", reply.body);
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
async fn list_answers_the_full_row_ordered_by_id() {
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

    // Every row is the full track as the upload answer shows it, including who added it: the
    // library is shared, so a bare user id would show nothing. A row inserted without tags reads as
    // an empty artist and a length of 0, which is what the client shows as a dash.
    for entry in &entries {
        let object = entry.as_object().expect("an entry is an object");
        assert_eq!(object.len(), 9, "an entry does not carry the documented row: {entry}");
        assert_eq!(entry["uploaded_by"].as_str(), Some("lukas"), "an entry does not name who added it: {entry}");
        assert_eq!(entry["artist"].as_str(), Some(""), "a row without tags does not read as empty: {entry}");
        assert_eq!(entry["duration_ms"].as_i64(), Some(0), "a row without tags does not read as empty: {entry}");
    }
}

/// A single lookup and the list read the same columns, so the two answers cannot disagree about
/// what a row contains. The client reads the answer; `get_by_id` is the lookup the stream endpoint
/// uses, and `user_id` only exists in that one — the answer shows the name it joined.
#[tokio::test]
async fn a_single_lookup_and_the_list_read_the_same_columns() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let uploaded = common::upload(&test, &token, "file", "mein lied.wav", &common::tiny_wav()).await;
    assert_eq!(uploaded.status, StatusCode::CREATED, "upload -> {} ({})", uploaded.status, uploaded.body);
    let from_answer = common::decode::<music::Track>(&uploaded.body);

    let list = common::get(&test, "/api/music", &token).await;
    assert_eq!(list.status, StatusCode::OK, "list -> {} ({})", list.status, list.body);
    let entries = common::decode::<Vec<music::Track>>(&list.body);
    assert_eq!(entries.len(), 1, "the list does not answer the row the upload created: {}", list.body);
    assert_eq!(documented(&entries[0]), documented(&from_answer), "the list answers other fields than the upload answer");

    let from_row = common::run(&test, move |conn| music::get_by_id(conn, from_answer.id)).await;
    assert_eq!(documented(&entries[0]), documented(&from_row), "the list and a single lookup disagree about the same row");
    assert!(from_row.user_id > 0, "the row does not record who uploaded the song");
}

/// What a player asks for: one part of the file, with the headers that say which part. A range
/// does not turn this endpoint into a whole-file read.
#[tokio::test]
async fn stream_answers_one_part_of_the_file_with_range_headers() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let big = big_wav();
    let reply = common::upload(&test, &token, "file", "song.wav", &big).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    let id = track["id"].as_i64().expect("the answer has an id");
    let stored = track["stored_name"].as_str().expect("the answer has a stored_name").to_string();
    let size = big.len();

    // Without a Range the whole file is still sent, and the caller is told it can ask for parts.
    // The download name is the stored name, which is what the upload answer reported.
    let whole = read_stream(&test, &format!("/api/music/{id}"), &token).await;
    assert_eq!(whole.status, StatusCode::OK, "whole file -> {}", whole.status);
    assert_eq!(whole.body, big, "the whole file was not sent, only {} bytes", whole.body.len());
    assert_eq!(header_value(&whole.headers, "accept-ranges"), "bytes", "a player needs to know the file can be read in parts");
    assert_eq!(
        header_value(&whole.headers, "content-disposition"),
        format!("inline; filename=\"{stored}\""),
        "Content-Disposition names something other than the file in the library folder",
    );

    // The first bytes, the part from an offset to the end, and the last bytes.
    let last = size - 1;
    let suffix_start = size - 4;
    for (range, wanted, content_range) in [
        ("bytes=0-3", big[..4].to_vec(), format!("bytes 0-3/{size}")),
        ("bytes=100-", big[100..].to_vec(), format!("bytes 100-{last}/{size}")),
        ("bytes=-4", big[suffix_start..].to_vec(), format!("bytes {suffix_start}-{last}/{size}")),
    ] {
        let part = read_range(&test, &format!("/api/music/{id}"), &token, range).await;
        assert_eq!(part.status, StatusCode::PARTIAL_CONTENT, "{range} -> {}, wanted 206", part.status);
        assert_eq!(part.body, wanted, "{range} sent {} bytes, wanted {}", part.body.len(), wanted.len());

        // A part is still an answer with the same headers, so the player is told what it got.
        assert_eq!(header_value(&part.headers, "accept-ranges"), "bytes", "{range} -> the caller must still be told that parts are possible");
        assert_eq!(
            header_value(&part.headers, "content-disposition"),
            format!("inline; filename=\"{stored}\""),
            "{range} -> Content-Disposition must name the file inside the library folder",
        );

        let answer_range = header_value(&part.headers, "content-range");
        assert_eq!(answer_range, content_range, "{range} answered Content-Range {answer_range}");

        let answer_length = header_value(&part.headers, "content-length");
        assert_eq!(answer_length, wanted.len().to_string(), "{range} answered Content-Length {answer_length}, wanted the length of the part");
    }

    // A range that ends at the last byte is the whole file, and it is served rather than refused:
    // the refusal rule is about a range that names nothing inside the file, not about a range that
    // happens to cover all of it.
    let whole = read_range(&test, &format!("/api/music/{id}"), &token, &format!("bytes=0-{last}")).await;
    assert_eq!(whole.status, StatusCode::PARTIAL_CONTENT, "the range that ends at the last byte was refused");
    assert_eq!(whole.body, big, "the range that ends at the last byte sent {} bytes, wanted the whole file", whole.body.len());

    // A range that spans more than one chunk still leaves piece by piece, which is why a player
    // can start playing before the end of the file is read.
    let part = read_range(&test, &format!("/api/music/{id}"), &token, "bytes=100-").await;
    assert!(
        part.pieces.len() >= 2,
        "a range over several chunks was sent in {} piece(s), not in chunks",
        part.pieces.len(),
    );
    for (number, piece) in part.pieces.iter().enumerate() {
        assert!(*piece > 0, "piece {number} added no bytes: {:?}", part.pieces);
        assert!(*piece <= music::CHUNK_BYTES, "piece {} sent {} bytes, more than the chunk size", number + 1, piece);
    }
}

/// A range that cannot be read as bytes, a list of ranges, or one that names nothing inside the
/// file. This is the one answer on this route that is not the JSON error shape, because the caller
/// here is a player and the error is about the transport.
///
/// The rest are the bounds `api-docs.md` claims: a range outside the file, a list of ranges, a
/// start past the last byte, a suffix larger than the file, and ends past the last byte. They are
/// refused rather than clamped, which is the difference from RFC 9110 the docs name, so a player
/// that sends `bytes=0-2147483647` gets 416 here. A range that ends at the last byte is the whole
/// file and is served, so it is not in this list.
#[tokio::test]
async fn stream_refuses_ranges_that_are_not_inside_the_file() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let big = big_wav();
    let reply = common::upload(&test, &token, "file", "song.wav", &big).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload -> {} ({})", reply.status, reply.body);

    let track = common::json(&reply.body);
    let id = track["id"].as_i64().expect("the answer has an id");
    let size = big.len();
    let auth = format!("Bearer {token}");

    for range in [
        "bytes=abc".to_string(),
        "bytes=99999-100000".to_string(),
        "bytes=0-1,4-5".to_string(),
        format!("bytes={size}-"),
        format!("bytes=-{}", size + 1),
        format!("bytes=0-{size}"),
        "bytes=0-2147483647".to_string(),
    ] {
        let reply = common::call(&test, "GET", &format!("/api/music/{id}"), b"", &[("authorization", auth.as_str()), ("range", range.as_str())]).await;
        assert_eq!(reply.status, StatusCode::RANGE_NOT_SATISFIABLE, "{range} -> {}, wanted 416 ({})", reply.status, reply.body);

        let content_type = common::header(&reply, "content-type");
        assert!(content_type.starts_with("text/plain"), "{range} answered {content_type}, but api-docs.md says plain text");

        let content_range = common::header(&reply, "content-range");
        assert_eq!(content_range, format!("bytes */{size}"), "{range} answered Content-Range {content_range}, which does not name the whole size");

        // The plain text body is what api-docs.md documents for this one answer, so the JSON
        // error shape must not appear here.
        assert_eq!(reply.body, "invalid range", "{range} answered {}, wanted the documented plain text", reply.body);
    }
}

/// A file of 0 bytes has no part inside it, so no range can name bytes in it. `api-docs.md` does
/// not document an answer for a 0-byte file, because the upload endpoint refuses an empty file — a
/// row like that only exists when it is inserted directly — so the rule is checked where the code
/// decides it. The range is `i64` because the length of such a file is 0: with an unsigned
/// inclusive end the answer would claim 1 byte for a file that has none.
#[test]
fn no_range_can_be_read_from_an_empty_file() {
    for range in ["bytes=0-3", "bytes=0-", "bytes=-1", "bytes=0-0"] {
        assert_eq!(music::parse_byte_range(range, 0), None, "{range} names bytes that are not in an empty file");
    }
}

/// A table created before the metadata columns existed is not changed by `CREATE TABLE IF NOT
/// EXISTS`, so the columns have to be added for an existing `saphire.db`.
#[tokio::test]
async fn ensure_columns_adds_the_missing_columns_to_an_old_track_table() {
    let test = common::setup().await;

    common::run(&test, |conn| {
        conn.execute("DROP TABLE track", ()).map_err(db::failure)?;
        conn.execute(
            "CREATE TABLE track (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL REFERENCES user(id),
                title TEXT NOT NULL,
                stored_name TEXT NOT NULL UNIQUE,
                size INTEGER NOT NULL,
                content_type TEXT NOT NULL,
                uploaded_at INTEGER NOT NULL
            )",
            (),
        )
        .map_err(db::failure)?;
        Ok(())
    })
    .await;

    // An old row must survive and read as an untagged file, not fail. The id comes from the insert,
    // not from the assumption that both rows happened to be the first ones.
    let track_id = common::run(&test, |conn| {
        conn.execute("INSERT INTO user (username, password_hash) VALUES (?1, ?2)", ("lukas", "not-a-bcrypt-hash"))
            .map_err(db::failure)?;
        let user_id = conn.last_insert_rowid();

        conn.execute(
            "INSERT INTO track (user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            (user_id, "alt.mp3", "old", 1, "audio/mpeg", 0),
        )
        .map_err(db::failure)?;

        music::ensure_columns(conn).map_err(db::failure)?;
        Ok(conn.last_insert_rowid())
    })
    .await;

    let track = common::run(&test, move |conn| music::get_by_id(conn, track_id)).await;
    assert_eq!(track.artist, "", "an old row read as {track:?}, wanted the empty defaults");
    assert_eq!(track.duration_ms, 0, "an old row read as {track:?}, wanted the empty defaults");

    // Running it again does not add a column twice, which is why it checks what is already there.
    common::run(&test, |conn| music::ensure_columns(conn).map_err(db::failure)).await;

    for column in ["artist", "duration_ms"] {
        let times = common::run(&test, move |conn| {
            let times: i64 = conn
                .query_row("SELECT COUNT(*) FROM pragma_table_info('track') WHERE name = ?1", (column,), |row| row.get(0))
                .map_err(db::failure)?;
            Ok(times)
        })
        .await;

        assert_eq!(times, 1, "column {column} is present {times} times after the migration ran twice");
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
