mod common;

use std::sync::Arc;
use std::time::Duration;

use axum::http::StatusCode;
use saphire_server::{app, db, music, queue, ratelimit};

use common::Test;

/// Uploads one file through the endpoint and reads the track as the client would, so the
/// tests work with real library rows.
async fn upload_track(test: &Test, token: &str, name: &str) -> music::Track {
    let reply = common::upload(test, token, "file", name, &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload {name} -> {} ({})", reply.status, reply.body);

    serde_json::from_str::<music::Track>(&reply.body).expect("the upload answer is one track")
}

/// Reads a GET /api/queue answer as a client would.
async fn read_queue(test: &Test, token: &str) -> Vec<queue::QueueEntry> {
    let reply = common::get(test, "/api/queue", token).await;
    assert_eq!(reply.status, StatusCode::OK, "queue -> {} ({})", reply.status, reply.body);

    serde_json::from_str::<Vec<queue::QueueEntry>>(&reply.body).expect("the answer is a list of entries")
}

/// Reads one answer that is a single entry, as the client that just added a song reads it.
fn entry(body: &str) -> queue::QueueEntry {
    serde_json::from_str::<queue::QueueEntry>(body).expect("the answer is one entry")
}

/// Creates a playlist and returns its id.
async fn create_playlist(test: &Test, token: &str, name: &str) -> i64 {
    let reply = common::post(test, "/api/playlists", &format!(r#"{{"name": "{name}"}}"#), token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "create playlist {name} -> {} ({})", reply.status, reply.body);

    common::json(&reply.body)["id"].as_i64().expect("the answer has an id")
}

async fn add_playlist_song(test: &Test, token: &str, playlist: i64, track_id: i64) {
    let reply = common::post(
        test,
        &format!("/api/playlists/{playlist}/songs"),
        &format!(r#"{{"track_id": {track_id}}}"#),
        token,
    )
    .await;
    assert_eq!(reply.status, StatusCode::CREATED, "add to playlist {playlist} -> {} ({})", reply.status, reply.body);
}

/// Reads the id a test user got, so a test can insert rows the way the endpoint would.
async fn user_id(test: &Test, username: &str) -> i64 {
    let name = username.to_string();

    common::run(test, move |conn| {
        let id: i64 = conn
            .query_row("SELECT id FROM user WHERE username = ?1", (&name,), |row| row.get(0))
            .map_err(db::failure)?;
        Ok(id)
    })
    .await
}

#[tokio::test]
async fn queue_requires_auth() {
    // Big capacity so only the credentials decide the status.
    let test = common::setup().await;

    // A missing header is its own error, so the client knows what to fix.
    let reply = common::get(&test, "/api/queue", "").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "anonymous queue -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("authorization header"), "anonymous queue did not name the missing header: {}", reply.body);

    let reply = common::post(&test, "/api/queue", r#"{"source": "library"}"#, "not-a-known-token").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "unknown token -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("session is not valid or expired"), "unknown token did not answer with the session message: {}", reply.body);
}

// The design point: the queue stores which songs in which order and nothing about what
// filled it. A playlist is one source, so a plain queue feature later is another source,
// not a different queue.
#[tokio::test]
async fn queue_is_only_songs_and_order() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    // A source name the queue does not know is refused with the names it does know.
    let reply = common::post(&test, "/api/queue", r#"{"source": "search"}"#, &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "unknown source -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("source must be"), "the refusal does not name the sources: {}", reply.body);

    // The whole library needs no source_id; sending one is not silently ignored.
    let reply = common::post(&test, "/api/queue", r#"{"source": "library", "source_id": 4}"#, &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "source_id with library -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("source_id is not used for the whole library"), "the refusal does not say why: {}", reply.body);

    // A source that names something needs a real id.
    let reply = common::post(&test, "/api/queue", r#"{"source": "playlist", "source_id": 0}"#, &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "source_id 0 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("source_id must be a positive number"), "the refusal does not name the field: {}", reply.body);

    // An empty playlist fills an empty queue. That is what an empty playlist means, and it
    // is not an error — and it answers as an array, not as null.
    let playlist = create_playlist(&test, &token, "Leer").await;
    let reply = common::post(&test, "/api/queue", &format!(r#"{{"source": "playlist", "source_id": {playlist}}}"#), &token).await;
    assert_eq!(reply.status, StatusCode::OK, "fill from an empty playlist -> {} ({})", reply.status, reply.body);
    assert_eq!(reply.body.trim(), "[]", "an empty queue must answer as an empty array, not null: {}", reply.body);

    // An entry has position, track_id and title and nothing else. There is no field that
    // could say what filled the queue, so any source produces the same shape.
    let track = upload_track(&test, &token, "lied.wav").await;
    let track_id = track.id;
    common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;

    let reply = common::get(&test, "/api/queue", &token).await;
    let raw = common::json(&reply.body);
    let rows = raw.as_array().expect("the answer is a list of entries");
    assert_eq!(rows.len(), 1, "queue has {} entries, wanted 1 ({})", rows.len(), reply.body);

    let object = rows[0].as_object().expect("the entry is an object");
    let mut keys: Vec<&str> = object.keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["position", "title", "track_id"], "an entry carries {keys:?}, which would record where it came from");
}

// A queue is filled in the order the source gives, which for a playlist is its positions,
// not the library order.
#[tokio::test]
async fn fill_from_playlist_keeps_the_playlist_order() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let playlist = create_playlist(&test, &token, "Favoriten").await;
    let first = upload_track(&test, &token, "eins.wav").await;
    let second = upload_track(&test, &token, "zwei.wav").await;

    // The playlist order is the second song first, so the queue must follow it.
    add_playlist_song(&test, &token, playlist, second.id).await;
    add_playlist_song(&test, &token, playlist, first.id).await;

    let reply = common::post(&test, "/api/queue", &format!(r#"{{"source": "playlist", "source_id": {playlist}}}"#), &token).await;
    assert_eq!(reply.status, StatusCode::OK, "fill from playlist -> {} ({})", reply.status, reply.body);

    let entries = serde_json::from_str::<Vec<queue::QueueEntry>>(&reply.body).expect("the answer is a list of entries");
    assert_eq!(entries.len(), 2, "queue has {} entries, wanted 2 ({})", entries.len(), reply.body);
    assert_eq!(entries[0].track_id, second.id, "the queue is not in the playlist order: {entries:?}");
    assert_eq!(entries[1].track_id, first.id, "the queue is not in the playlist order: {entries:?}");
    assert_eq!(entries[0].position, 1, "the queue positions are not 1..n: {entries:?}");
    assert_eq!(entries[1].position, 2, "the queue positions are not 1..n: {entries:?}");

    // Only the caller's own playlist can fill a queue.
    let other = common::token(&test, "andere", "valid-password").await;
    let reply = common::post(&test, "/api/queue", &format!(r#"{{"source": "playlist", "source_id": {playlist}}}"#), &other).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "other user filling from it -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("not in your playlists"), "the refusal does not name the ownership rule: {}", reply.body);
}

// Filling is not adding. A player that starts a second playlist must not keep the songs of
// the first.
#[tokio::test]
async fn fill_replaces_the_queue() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let one = upload_track(&test, &token, "eins.wav").await;
    let two = upload_track(&test, &token, "zwei.wav").await;

    let erste = create_playlist(&test, &token, "erste").await;
    let zweite = create_playlist(&test, &token, "zweite").await;
    add_playlist_song(&test, &token, erste, one.id).await;
    add_playlist_song(&test, &token, zweite, two.id).await;

    common::post(&test, "/api/queue", &format!(r#"{{"source": "playlist", "source_id": {erste}}}"#), &token).await;
    common::post(&test, "/api/queue", &format!(r#"{{"source": "playlist", "source_id": {zweite}}}"#), &token).await;

    let entries = read_queue(&test, &token).await;
    assert_eq!(entries.len(), 1, "the second fill did not replace the first: {entries:?}");
    assert_eq!(entries[0].track_id, two.id, "the second fill did not replace the first: {entries:?}");

    // A single song is a source too, which is what "play this now" needs.
    let reply = common::post(&test, "/api/queue", &format!(r#"{{"source": "track", "source_id": {}}}"#, one.id), &token).await;
    assert_eq!(reply.status, StatusCode::OK, "fill from one song -> {} ({})", reply.status, reply.body);

    let single = serde_json::from_str::<Vec<queue::QueueEntry>>(&reply.body).expect("the answer is a list of entries");
    assert_eq!(single.len(), 1, "one song as a source answered {single:?}");
    assert_eq!(single[0].track_id, one.id, "one song as a source answered {single:?}");
    assert_eq!(single[0].position, 1, "one song as a source answered {single:?}");

    // The whole library is the third source, ordered by id.
    let reply = common::post(&test, "/api/queue", r#"{"source": "library"}"#, &token).await;
    assert_eq!(reply.status, StatusCode::OK, "fill from the library -> {} ({})", reply.status, reply.body);

    let library = serde_json::from_str::<Vec<queue::QueueEntry>>(&reply.body).expect("the answer is a list of entries");
    assert_eq!(library.len(), 2, "the library source answered {library:?}, wanted both songs by id");
    assert_eq!(library[0].track_id, one.id, "the library source answered {library:?}, wanted both songs by id");
    assert_eq!(library[1].track_id, two.id, "the library source answered {library:?}, wanted both songs by id");
}

// A source that names one song cannot be an empty list. Answering 200 with [] here would
// also wipe the queue that was there, so the refusal has to happen before anything is
// deleted.
#[tokio::test]
async fn fill_from_unknown_track_names_the_song() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let track = upload_track(&test, &token, "lied.wav").await;
    let track_id = track.id;
    common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;

    let reply = common::post(&test, "/api/queue", r#"{"source": "track", "source_id": 9999}"#, &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "unknown song as a source -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("song is not in the library"), "the refusal does not name the song: {}", reply.body);

    let entries = read_queue(&test, &token).await;
    assert_eq!(entries.len(), 1, "the failed fill left {entries:?}, wanted the queue as it was before");
    assert_eq!(entries[0].track_id, track.id, "the failed fill left {entries:?}, wanted the queue as it was before");
}

// The plain queue feature on the server side: add one song at the end without a source, and
// the limit is a real limit rather than a silent drop.
#[tokio::test]
async fn append_queue_entry() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let track = upload_track(&test, &token, "lied.wav").await;
    let track_id = track.id;

    let reply = common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "append -> {} ({})", reply.status, reply.body);

    let added = entry(&reply.body);
    assert_eq!(added.position, 1, "append answered {added:?}, wanted position 1");
    assert_eq!(added.track_id, track_id, "append answered {added:?}, wanted the song it was asked for");
    assert_eq!(added.title, track.title, "append answered {added:?}, wanted the title from the library");

    // The same song twice is allowed, because a queue is an order, not a set.
    let reply = common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "the same song twice -> {} ({})", reply.status, reply.body);

    let reply = common::post(&test, "/api/queue/songs", r#"{"track_id": 9999}"#, &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "unknown track -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("song is not in the library"), "the refusal does not name the song: {}", reply.body);

    // A body that is not one object with track_id, and a body over the limit, are refused
    // the same way as the register endpoint.
    let reply = common::post(&test, "/api/queue/songs", r#"{"track_id": 1} {"track_id": 2}"#, &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "two objects -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("exactly one JSON object"), "the refusal does not say what the body was: {}", reply.body);

    // Two rows are already there, so the loop fills to the cap and the request below is the
    // one that crosses it. Positions stay 1..n, the contiguity this test is about.
    let user = user_id(&test, "lukas").await;
    common::run(&test, move |conn| {
        for position in 3..=queue::MAX_ENTRIES {
            conn.execute(
                "INSERT INTO queue_entry (user_id, position, track_id, added_at) VALUES (?1, ?2, ?3, ?4)",
                (user, position, track_id, 1),
            )
            .map_err(db::failure)?;
        }
        Ok(())
    })
    .await;

    let reply = common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "adding past the cap -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("holds at most 200 songs"), "the refusal does not name the cap: {}", reply.body);
}

// Counting and inserting are one piece of work, so two callers writing at the same moment
// cannot be handed the same number. This only holds while the write path has one connection
// — with a pool the second caller gets a second connection, and a ":memory:" database is a
// different database on each one.
#[tokio::test]
async fn two_appends_do_not_get_the_same_position() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let one = upload_track(&test, &token, "a.wav").await;
    let two = upload_track(&test, &token, "b.wav").await;
    let first_body = format!(r#"{{"track_id": {}}}"#, one.id);
    let second_body = format!(r#"{{"track_id": {}}}"#, two.id);

    // Both requests are in flight at the same time.
    let (first, second) = tokio::join!(
        common::post(&test, "/api/queue/songs", &first_body, &token),
        common::post(&test, "/api/queue/songs", &second_body, &token),
    );

    for reply in [&first, &second] {
        assert_eq!(reply.status, StatusCode::CREATED, "append -> {} ({})", reply.status, reply.body);
    }

    let positions = [entry(&first.body).position, entry(&second.body).position];
    assert!(
        positions[0] != positions[1],
        "both callers got position {}, wanted 1 and 2",
        positions[0]
    );

    let entries = read_queue(&test, &token).await;
    assert_eq!(entries.len(), 2, "the queue has {} rows, wanted 2", entries.len());
    for entry in &entries {
        assert!((1..=2).contains(&entry.position), "row at position {}, wanted a position in 1..2", entry.position);
    }
}

// A source with more songs than a queue holds is refused and the queue stays as it was — a
// fill that is refused must not leave half of it. The cap is read with the query, so a
// library larger than a queue is not copied into memory only to be refused.
#[tokio::test]
async fn fill_past_the_cap_keeps_the_queue() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let track = upload_track(&test, &token, "lied.wav").await;
    let track_id = track.id;
    let user = user_id(&test, "lukas").await;

    // Rows written the way the endpoint would write them, so the library is one song past
    // the cap.
    common::run(&test, move |conn| {
        for row in 0..queue::MAX_ENTRIES {
            conn.execute(
                "INSERT INTO track (user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                (user, "song", format!("row-{row}"), 1, "audio/wav", 1),
            )
            .map_err(db::failure)?;
        }
        Ok(())
    })
    .await;

    common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;

    let reply = common::post(&test, "/api/queue", r#"{"source": "library"}"#, &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "filling past the cap -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("holds at most 200 songs"), "the refusal does not name the cap: {}", reply.body);

    let entries = read_queue(&test, &token).await;
    assert_eq!(entries.len(), 1, "the refused fill left {entries:?}, wanted the queue as it was");
    assert_eq!(entries[0].track_id, track_id, "the refused fill left {entries:?}, wanted the queue as it was");
}

// The same promise as a playlist: positions stay 1..n with no gaps, and an empty slot names
// the position it was asked about.
#[tokio::test]
async fn remove_queue_entry_renames_positions() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let mut ids = Vec::new();
    for name in ["eins.wav", "zwei.wav", "drei.wav"] {
        let track = upload_track(&test, &token, name).await;
        ids.push(track.id);
        common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {}}}"#, track.id), &token).await;
    }

    let reply = common::delete(&test, "/api/queue/2", &token).await;
    assert_eq!(reply.status, StatusCode::NO_CONTENT, "remove -> {} ({})", reply.status, reply.body);
    assert!(reply.body.is_empty(), "remove answered a body: {}", reply.body);

    let entries = read_queue(&test, &token).await;
    assert_eq!(entries.len(), 2, "positions after a remove are not 1..n: {entries:?}");
    assert_eq!(entries[0].position, 1, "positions after a remove are not 1..n: {entries:?}");
    assert_eq!(entries[1].position, 2, "positions after a remove are not 1..n: {entries:?}");
    assert_eq!(entries[0].track_id, ids[0], "the wrong songs are left: {entries:?}");
    assert_eq!(entries[1].track_id, ids[2], "the wrong songs are left: {entries:?}");

    let reply = common::delete(&test, "/api/queue/3", &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "empty slot -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("no song at position 3 in this queue"), "the refusal does not name the position and the queue: {}", reply.body);

    let reply = common::delete(&test, "/api/queue/+3", &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "position +3 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("position must be a positive number"), "the refusal does not name the field: {}", reply.body);

    // Digits that do not fit an int64 are answered as too large. The position is kept as an
    // i64 through the whole path, so a 32-bit build does not answer about a wrapped slot
    // instead.
    let reply = common::delete(&test, "/api/queue/9223372036854775808", &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "position past int64 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("position is too large"), "the refusal says the wrong thing about a too-large position: {}", reply.body);

    // A queue is per user: another user's queue is not touched.
    let other = common::token(&test, "andere", "valid-password").await;
    let entries = read_queue(&test, &other).await;
    assert_eq!(entries.len(), 0, "the other user sees {} entries, wanted none", entries.len());
}

#[tokio::test]
async fn clear_queue() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let track = upload_track(&test, &token, "lied.wav").await;
    let track_id = track.id;
    common::post(&test, "/api/queue/songs", &format!(r#"{{"track_id": {track_id}}}"#), &token).await;

    let reply = common::delete(&test, "/api/queue", &token).await;
    assert_eq!(reply.status, StatusCode::NO_CONTENT, "clear -> {} ({})", reply.status, reply.body);
    assert!(reply.body.is_empty(), "clear answered a body: {}", reply.body);

    let entries = read_queue(&test, &token).await;
    assert_eq!(entries.len(), 0, "the queue is not empty after a clear: {entries:?}");

    // The song is still in the library: a queue holds references, not files.
    let reply = common::get(&test, "/api/music", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "library -> {} ({})", reply.status, reply.body);

    let library = common::json(&reply.body);
    let rows = library.as_array().expect("the answer is a list of songs");
    assert!(
        rows.iter().any(|row| row["id"].as_i64() == Some(track_id) && row["title"].as_str() == Some("lied.wav")),
        "the song is gone from the library after the queue was cleared: {}",
        reply.body
    );
}

// Checks both directions with two limiter instances the way main.go wires them — that is also
// all this test can prove, since a shared instance would fail here.
#[tokio::test]
async fn queue_and_playlist_buckets_are_separate() {
    // A wide refill window on purpose: with a one second window the tokens between two
    // requests would depend on how fast this machine answers, so the test would measure the
    // machine instead of the limit.
    let mut full = app::test_limiters();
    full.queue = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    full.playlist = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&full).await;
    let token = common::token(&test, "lukas", "valid-password").await;

    for request in 1..=2 {
        let reply = common::get(&test, "/api/queue", &token).await;
        assert_eq!(reply.status, StatusCode::OK, "queue {request} -> {} ({})", reply.status, reply.body);
    }

    let reply = common::get(&test, "/api/queue", &token).await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third queue request -> {} ({})", reply.status, reply.body);
    common::check_retry_after(&reply, 60);

    let reply = common::get(&test, "/api/playlists", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "a full queue bucket stopped the playlists -> {} ({})", reply.status, reply.body);

    // The other way round: a full playlist bucket must not stop a player reading its queue.
    let mut other = app::test_limiters();
    other.queue = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    other.playlist = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&other).await;
    let token = common::token(&test, "lukas", "valid-password").await;

    for request in 1..=2 {
        let reply = common::get(&test, "/api/playlists", &token).await;
        assert_eq!(reply.status, StatusCode::OK, "playlist {request} -> {} ({})", reply.status, reply.body);
    }

    let reply = common::get(&test, "/api/playlists", &token).await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third playlist request -> {} ({})", reply.status, reply.body);
    common::check_retry_after(&reply, 60);

    let reply = common::get(&test, "/api/queue", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "a full playlist bucket stopped the queue -> {} ({})", reply.status, reply.body);
}
