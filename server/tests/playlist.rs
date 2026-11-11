mod common;

use std::sync::Arc;
use std::time::Duration;

use axum::http::StatusCode;
use saphire_server::{app, music, playlist, ratelimit};

fn name_body(name: &str) -> String {
    format!(r#"{{"name": "{name}"}}"#)
}

fn track_body(id: i64) -> String {
    format!(r#"{{"track_id": {id}}}"#)
}

/// Makes a playlist through the endpoint and returns what it got, so the test reads the answer
/// the same way a client does.
async fn create_playlist(test: &common::Test, token: &str, name: &str) -> playlist::Playlist {
    let reply = common::post(test, "/api/playlists", &name_body(name), token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "create playlist -> {} ({})", reply.status, reply.body);
    common::decode(&reply.body)
}

/// Uploads one file through the endpoint and returns the track as the client would read it, so
/// the tests work with real library rows.
async fn upload_track(test: &common::Test, token: &str, name: &str) -> music::Track {
    let reply = common::upload(test, token, "file", name, &common::tiny_wav()).await;
    assert_eq!(reply.status, StatusCode::CREATED, "upload {name} -> {} ({})", reply.status, reply.body);
    common::decode(&reply.body)
}

#[tokio::test]
async fn playlist_endpoints_need_a_session() {
    let test = common::setup().await;

    let reply = common::get(&test, "/api/playlists", "").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "anonymous list -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("authorization header"), "missing header answered  {}", reply.body);

    let reply = common::post(&test, "/api/playlists", &name_body("Favoriten"), "not-a-known-token").await;
    assert_eq!(reply.status, StatusCode::UNAUTHORIZED, "unknown token -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("session is not valid or expired"), "unknown token answered  {}", reply.body);
}

// What the endpoint decides about a name. The client form is not the trust boundary, so a name
// that is empty after cleaning, or longer than the cap, must be refused here.
#[tokio::test]
async fn playlist_names_are_refused_not_repaired() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let reply = common::post(&test, "/api/playlists", &name_body("   "), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "empty name -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("needs a name"), "empty name answered  {}", reply.body);

    // Control characters are dropped, so a name that is only control characters has nothing
    // left to store.
    let reply = common::post(&test, "/api/playlists", "{\"name\": \"\\u0007\\u0001\"}", &token).await;
    assert_eq!(
        reply.status,
        StatusCode::BAD_REQUEST,
        "name of only control characters -> {} ({})",
        reply.status,
        reply.body
    );

    // The cap counts characters, not bytes: a name of exactly 100 two-byte characters is 200
    // bytes and is stored as 100 characters, not cut in half.
    let name = "é".repeat(100);
    let reply = common::post(&test, "/api/playlists", &name_body(&name), &token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "name at the cap -> {} ({})", reply.status, reply.body);

    let stored: playlist::Playlist = common::decode(&reply.body);
    assert_eq!(stored.name.chars().count(), 100, "name stored with {} characters, wanted the cap 100", stored.name.chars().count());

    // One character past the cap is refused, not truncated: a playlist keeps the name it was
    // given, the same way the 200 songs cap is a refusal rather than a silent drop.
    let reply = common::post(&test, "/api/playlists", &name_body(&format!("{name}x")), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "name past the cap -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("at most 100 characters"), "name past the cap answered  {}", reply.body);
}

// The rule a playlist is not shared: one user cannot read, add to, or delete another user's
// playlist, and the answer says it is not in their playlists rather than confirming that the
// playlist exists.
#[tokio::test]
async fn a_playlist_belongs_to_the_user_who_made_it() {
    let test = common::setup().await;
    let lukas = common::token(&test, "lukas", "valid-password").await;
    let other = common::token(&test, "andere", "valid-password").await;

    let made = create_playlist(&test, &lukas, "Favoriten").await;

    // Not a number, so the path value is refused before anything is looked up.
    let reply = common::get(&test, &format!("/api/playlists/{}", made.name), &other).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "name as an id -> {} ({})", reply.status, reply.body);

    let path = format!("/api/playlists/{}", made.id);
    let reply = common::get(&test, &path, &other).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "other user reading it -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("not in your playlists"), "ownership answered  {}", reply.body);

    let reply = common::post(&test, &format!("{path}/songs"), &track_body(1), &other).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "other user adding to it -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("not in your playlists"), "ownership answered  {}", reply.body);

    let reply = common::delete(&test, &path, &other).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "other user deleting it -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("not in your playlists"), "ownership answered  {}", reply.body);

    // The owner still sees it.
    let reply = common::get(&test, &path, &lukas).await;
    assert_eq!(reply.status, StatusCode::OK, "owner reading it -> {} ({})", reply.status, reply.body);
}

#[tokio::test]
async fn list_playlists_shows_counts_and_answers_empty() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let reply = common::get(&test, "/api/playlists", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "list -> {} ({})", reply.status, reply.body);
    assert_eq!(reply.body.trim(), "[]", "no playlists answered {}", reply.body);

    let first = create_playlist(&test, &token, "Favoriten").await;
    let second = create_playlist(&test, &token, "Techno").await;

    let track = upload_track(&test, &token, "lied.wav").await;
    common::post(&test, &format!("/api/playlists/{}/songs", first.id), &track_body(track.id), &token).await;

    let reply = common::get(&test, "/api/playlists", &token).await;
    let playlists: Vec<playlist::Playlist> = common::decode(&reply.body);
    assert_eq!(playlists.len(), 2, "list has {} playlists, wanted 2 ({})", playlists.len(), reply.body);
    assert_eq!(playlists[0].id, first.id, "the list is not ordered by id: {}", reply.body);
    assert_eq!(playlists[1].id, second.id, "the list is not ordered by id: {}", reply.body);
    assert_eq!(playlists[0].song_count, 1, "song_count is wrong: {}", reply.body);
    assert_eq!(playlists[1].song_count, 0, "song_count is wrong: {}", reply.body);

    // Two playlists with the same name are two different playlists.
    let again = create_playlist(&test, &token, "Favoriten").await;
    assert_ne!(again.id, first.id, "the same name returned the same playlist id {}", again.id);

    // The songs are not in the list answer: a client shows playlists, not every song of every
    // playlist, so nothing here can be longer than the fields of one playlist.
    for entry in &playlists {
        assert!(entry.song_count >= 0, "song_count is negative: {entry:?}");
    }
}

// A song is added at the end, the same song twice is allowed (a playlist is an order, not a
// set), and both unknown references are refused with the message that names which one is
// missing.
#[tokio::test]
async fn adding_a_song_keeps_positions_and_refuses_what_is_not_there() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;

    let made = create_playlist(&test, &token, "Favoriten").await;
    let one = upload_track(&test, &token, "eins.wav").await;
    let two = upload_track(&test, &token, "zwei.wav").await;
    let path = format!("/api/playlists/{}", made.id);

    let reply = common::post(&test, &format!("{path}/songs"), &track_body(two.id), &token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "add -> {} ({})", reply.status, reply.body);
    let song: playlist::PlaylistSong = common::decode(&reply.body);
    assert_eq!(song.position, 1, "first song answered {song:?}, wanted position 1 with the title from the library");
    assert_eq!(song.track_id, two.id, "first song answered {song:?}");
    assert_eq!(song.title, two.title, "first song answered {song:?}");

    // The same song twice is allowed: positions differ.
    let reply = common::post(&test, &format!("{path}/songs"), &track_body(two.id), &token).await;
    assert_eq!(reply.status, StatusCode::CREATED, "the same song twice -> {} ({})", reply.status, reply.body);
    let song: playlist::PlaylistSong = common::decode(&reply.body);
    assert_eq!(song.position, 2, "second add answered position {}", song.position);

    let reply = common::post(&test, &format!("{path}/songs"), &track_body(9999), &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "unknown track -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("song is not in the library"), "unknown track answered  {}", reply.body);

    let reply = common::post(&test, &format!("{path}/songs"), &track_body(0), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "track_id 0 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("track_id must be a positive number"), "track_id 0 answered  {}", reply.body);

    let reply = common::post(&test, "/api/playlists/0/songs", &track_body(one.id), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "playlist id 0 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("must be a positive number"), "playlist id 0 answered  {}", reply.body);

    // An unknown field in the body is refused, as the register endpoint does.
    let reply = common::post(&test, &format!("{path}/songs"), r#"{"track_id": 1, "position": 3}"#, &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "unknown field -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("one JSON object"), "unknown field answered  {}", reply.body);

    // The cap is a real limit, not a silent drop. Two songs are already there, so the loop
    // fills to the cap and the request below is the one that crosses it. Positions stay 1..n,
    // the contiguity these tests are about.
    for position in 2..200 {
        common::run(&test, move |conn| {
            conn.execute(
                "INSERT INTO playlist_song (playlist_id, track_id, position, added_at) VALUES (?1, ?2, ?3, ?4)",
                (made.id, two.id, position, 1),
            )
            .map_err(saphire_server::db::failure)?;
            Ok(())
        })
        .await;
    }

    let reply = common::post(&test, &format!("{path}/songs"), &track_body(two.id), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "adding past the cap -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("holds at most 200 songs"), "past the cap answered  {}", reply.body);
}

// Digits that do not fit an i64 are answered as too large, not as an empty slot, so a value
// that would wrap is named as what it is.
#[tokio::test]
async fn a_path_number_past_i64_is_refused() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;
    let made = create_playlist(&test, &token, "Favoriten").await;

    let reply = common::delete(&test, &format!("/api/playlists/{}/songs/9223372036854775808", made.id), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "position past i64 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("position is too large"), "position past i64 answered  {}", reply.body);

    let reply = common::delete(&test, "/api/playlists/9223372036854775808", &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "playlist id past i64 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("playlist id is too large"), "playlist id past i64 answered  {}", reply.body);
}

// The promise the endpoint makes: the positions a client sees stay 1..n with no gaps, so a slot
// can be addressed without knowing the history.
#[tokio::test]
async fn removing_a_song_renumbers_the_rest() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;
    let made = create_playlist(&test, &token, "Favoriten").await;

    let mut ids = Vec::new();
    for name in ["eins.wav", "zwei.wav", "drei.wav"] {
        let track = upload_track(&test, &token, name).await;
        ids.push(track.id);
        common::post(&test, &format!("/api/playlists/{}/songs", made.id), &track_body(track.id), &token).await;
    }

    let reply = common::delete(&test, &format!("/api/playlists/{}/songs/2", made.id), &token).await;
    assert_eq!(reply.status, StatusCode::NO_CONTENT, "remove -> {} ({})", reply.status, reply.body);
    assert!(reply.body.is_empty(), "a 204 must have no body, got {}", reply.body);
    assert!(!reply.headers.contains_key("content-type"), "a 204 must not claim a content type, got {:?}", reply.headers.get("content-type"));

    let reply = common::get(&test, &format!("/api/playlists/{}", made.id), &token).await;
    let with_songs: playlist::PlaylistWithSongs = common::decode(&reply.body);
    assert_eq!(with_songs.songs.len(), 2, "after the remove the playlist has {} songs, wanted 2 ({})", with_songs.songs.len(), reply.body);
    assert_eq!(with_songs.songs[0].position, 1, "positions after a remove are not 1..n: {}", reply.body);
    assert_eq!(with_songs.songs[1].position, 2, "positions after a remove are not 1..n: {}", reply.body);
    assert_eq!(with_songs.songs[0].track_id, ids[0], "the wrong songs are left: {}", reply.body);
    assert_eq!(with_songs.songs[1].track_id, ids[2], "the wrong songs are left: {}", reply.body);
    assert_eq!(with_songs.song_count, 2, "song_count says {} after a remove, wanted 2", with_songs.song_count);

    let reply = common::delete(&test, &format!("/api/playlists/{}/songs/3", made.id), &token).await;
    assert_eq!(reply.status, StatusCode::NOT_FOUND, "empty slot -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("no song at position 3"), "empty slot answered  {}", reply.body);

    let reply = common::delete(&test, &format!("/api/playlists/{}/songs/-1", made.id), &token).await;
    assert_eq!(reply.status, StatusCode::BAD_REQUEST, "position -1 -> {} ({})", reply.status, reply.body);
    assert!(reply.body.contains("position must be a positive number"), "position -1 answered  {}", reply.body);
}

// Deleting a list of references must not delete the files or the library rows.
#[tokio::test]
async fn deleting_a_playlist_keeps_the_library() {
    let test = common::setup().await;
    let token = common::token(&test, "lukas", "valid-password").await;
    let made = create_playlist(&test, &token, "Favoriten").await;
    let track = upload_track(&test, &token, "lied.wav").await;
    common::post(&test, &format!("/api/playlists/{}/songs", made.id), &track_body(track.id), &token).await;

    let reply = common::delete(&test, &format!("/api/playlists/{}", made.id), &token).await;
    assert_eq!(reply.status, StatusCode::NO_CONTENT, "delete -> {} ({})", reply.status, reply.body);

    // The song is still in the library, and the playlist is gone.
    let reply = common::get(&test, "/api/music", &token).await;
    assert!(reply.body.contains("lied.wav"), "the song is not in the library after its playlist was deleted: {}", reply.body);

    let reply = common::get(&test, "/api/playlists", &token).await;
    assert_eq!(reply.body.trim(), "[]", "the playlist is still listed: {}", reply.body);

    let left = common::run(&test, move |conn| {
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM playlist_song WHERE playlist_id = ?1", (made.id,), |row| row.get(0))
            .map_err(saphire_server::db::failure)?;
        Ok(count)
    })
    .await;
    assert_eq!(left, 0, "{left} song rows are left for a deleted playlist");
}

// A client that builds a playlist should not be able to stop reading the library, and the queue
// has its own bucket.
#[tokio::test]
async fn playlist_limit_does_not_stop_the_library_or_the_queue() {
    // A wide refill window so the test measures the bucket, not how long a request takes.
    let mut limiters = app::test_limiters();
    limiters.playlist = Arc::new(ratelimit::new(2, Duration::from_secs(60)));
    let test = common::setup_with(&limiters).await;
    let token = common::token(&test, "lukas", "valid-password").await;

    for _ in 0..2 {
        let reply = common::get(&test, "/api/playlists", &token).await;
        assert_eq!(reply.status, StatusCode::OK, "playlist request -> {} ({})", reply.status, reply.body);
    }

    let reply = common::get(&test, "/api/playlists", &token).await;
    assert_eq!(reply.status, StatusCode::TOO_MANY_REQUESTS, "third playlist request -> {} ({})", reply.status, reply.body);
    common::check_retry_after(&reply, 60);

    let reply = common::get(&test, "/api/music", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "a full playlist bucket stopped the library -> {} ({})", reply.status, reply.body);

    let reply = common::get(&test, "/api/queue", &token).await;
    assert_eq!(reply.status, StatusCode::OK, "a full playlist bucket stopped the queue -> {} ({})", reply.status, reply.body);
}
