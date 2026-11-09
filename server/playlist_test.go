package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"
)

// itoa is only for building test paths and bodies; the values are ids the test just
// got from the endpoint.
func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}

// uploadTrack uploads one file through the endpoint and returns the track as the client
// would read it, so the tests work with real library rows.
func uploadTrack(t *testing.T, handler http.HandlerFunc, token, name string) Track {
	t.Helper()

	rec := uploadFile(t, handler, token, "file", name, tinyWAV())
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload %s -> %d (%s)", name, rec.Code, rec.Body)
	}

	var track Track
	if err := json.Unmarshal(rec.Body.Bytes(), &track); err != nil {
		t.Fatalf("decode upload: %v", err)
	}
	return track
}

func playlistMux(db *sql.DB, limiter *rateLimiter) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/playlists", createPlaylistHandler(db, limiter))
	mux.HandleFunc("GET /api/playlists", listPlaylistsHandler(db, limiter))
	mux.HandleFunc("GET /api/playlists/{id}", getPlaylistHandler(db, limiter))
	mux.HandleFunc("POST /api/playlists/{id}/songs", addPlaylistSongHandler(db, limiter))
	mux.HandleFunc("DELETE /api/playlists/{id}/songs/{position}", removePlaylistSongHandler(db, limiter))
	mux.HandleFunc("DELETE /api/playlists/{id}", deletePlaylistHandler(db, limiter))
	return mux
}

// postJSON sends one JSON body with a Bearer token, through a mux so that
// r.PathValue has the value main.go would give it.
func postJSON(t *testing.T, handler http.Handler, path, token, body string) *httptest.ResponseRecorder {
	t.Helper()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	handler.ServeHTTP(rec, req)
	return rec
}

func deleteRequest(t *testing.T, handler http.Handler, path, token string) *httptest.ResponseRecorder {
	t.Helper()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodDelete, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	handler.ServeHTTP(rec, req)
	return rec
}

// createPlaylist makes a playlist through the endpoint and returns what it got, so the
// test reads the answer the same way a client does.
func createPlaylist(t *testing.T, handler http.Handler, token, name string) Playlist {
	t.Helper()

	rec := postJSON(t, handler, "/api/playlists", token, `{"name": "`+name+`"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("create playlist -> %d (%s)", rec.Code, rec.Body)
	}

	var p Playlist
	if err := json.Unmarshal(rec.Body.Bytes(), &p); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	return p
}

func TestPlaylistRequiresAuth(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))

	rec := get(t, handler, "/api/playlists", "")
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "authorization header") {
		t.Errorf("anonymous list -> %d (%s), wanted 401 with the missing-header message", rec.Code, rec.Body)
	}

	rec = postJSON(t, handler, "/api/playlists", "not-a-known-token", `{"name": "Favoriten"}`)
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "session is not valid or expired") {
		t.Errorf("unknown token -> %d (%s), wanted 401 with the session message", rec.Code, rec.Body)
	}
}

// TestPlaylistName covers what the endpoint decides about a name. The client form is
// not the trust boundary, so a name that is empty after cleaning, or longer than the
// cap, must be refused here.
func TestPlaylistName(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	rec := postJSON(t, handler, "/api/playlists", token, `{"name": "   "}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "needs a name") {
		t.Errorf("empty name -> %d (%s), wanted 400 saying a name is needed", rec.Code, rec.Body)
	}

	// Control characters are dropped, so a name that is only control characters has
	// nothing left to store.
	rec = postJSON(t, handler, "/api/playlists", token, "{\"name\": \"\\u0007\\u0001\"}")
	if rec.Code != http.StatusBadRequest {
		t.Errorf("name of only control characters -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// The cap counts characters, not bytes: a name of exactly 100 two-byte characters is
	// 200 bytes and is stored as 100 characters, not cut in half.
	name := strings.Repeat("é", maxPlaylistNameLen)
	rec = postJSON(t, handler, "/api/playlists", token, `{"name": "`+name+`"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("name at the cap -> %d (%s)", rec.Code, rec.Body)
	}

	var stored Playlist
	if err := json.Unmarshal(rec.Body.Bytes(), &stored); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if got := len([]rune(stored.Name)); got != maxPlaylistNameLen {
		t.Errorf("name stored with %d characters, wanted the cap %d", got, maxPlaylistNameLen)
	}

	// One character past the cap is refused, not truncated: a playlist keeps the name it
	// was given, the same way the 200 songs cap is a refusal rather than a silent drop.
	rec = postJSON(t, handler, "/api/playlists", token, `{"name": "`+name+`x"}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "at most 100 characters") {
		t.Errorf("name past the cap -> %d (%s), wanted 400 naming the cap", rec.Code, rec.Body)
	}
}

// TestPlaylistsAreTheUsersOwn checks the rule a playlist is not shared: one user cannot
// read, add to, or delete another user's playlist, and the answer says it is not in
// their playlists rather than confirming the playlist exists.
func TestPlaylistsAreTheUsersOwn(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))

	lukas := testToken(t, db, "lukas")
	other := testToken(t, db, "andere")

	playlist := createPlaylist(t, handler, lukas, "Favoriten")

	rec := get(t, handler, "/api/playlists/"+playlist.Name, other) // not a number, so 400
	if rec.Code != http.StatusBadRequest {
		t.Errorf("name as an id -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	rec = get(t, handler, "/api/playlists/"+itoa(playlist.ID), other)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "not in your playlists") {
		t.Errorf("other user reading it -> %d (%s), wanted 400/404 with the ownership message", rec.Code, rec.Body)
	}

	rec = postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", other, `{"track_id": 1}`)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "not in your playlists") {
		t.Errorf("other user adding to it -> %d (%s), wanted 404 with the ownership message", rec.Code, rec.Body)
	}

	rec = deleteRequest(t, handler, "/api/playlists/"+itoa(playlist.ID), other)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "not in your playlists") {
		t.Errorf("other user deleting it -> %d (%s), wanted 404 with the ownership message", rec.Code, rec.Body)
	}

	// The owner still sees it.
	rec = get(t, handler, "/api/playlists/"+itoa(playlist.ID), lukas)
	if rec.Code != http.StatusOK {
		t.Errorf("owner reading it -> %d (%s), wanted 200", rec.Code, rec.Body)
	}
}

func TestListPlaylistsShowsCountsAndAnswersEmptyList(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	rec := get(t, handler, "/api/playlists", token)
	if rec.Code != http.StatusOK {
		t.Fatalf("list -> %d (%s)", rec.Code, rec.Body)
	}
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("no playlists answered %s, wanted []", rec.Body)
	}

	first := createPlaylist(t, handler, token, "Favoriten")
	second := createPlaylist(t, handler, token, "Techno")

	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	track := uploadFile(t, upload, token, "file", "lied.wav", tinyWAV())
	var added Track
	if err := json.Unmarshal(track.Body.Bytes(), &added); err != nil {
		t.Fatalf("decode upload: %v", err)
	}
	postJSON(t, handler, "/api/playlists/"+itoa(first.ID)+"/songs", token, `{"track_id": `+itoa(added.ID)+`}`)

	rec = get(t, handler, "/api/playlists", token)
	var playlists []Playlist
	if err := json.Unmarshal(rec.Body.Bytes(), &playlists); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(playlists) != 2 {
		t.Fatalf("list has %d playlists, wanted 2 (%s)", len(playlists), rec.Body)
	}
	if playlists[0].ID != first.ID || playlists[1].ID != second.ID {
		t.Errorf("the list is not ordered by id: %s", rec.Body)
	}
	if playlists[0].SongCount != 1 || playlists[1].SongCount != 0 {
		t.Errorf("song_count is wrong: %s", rec.Body)
	}

	// Two playlists with the same name are two different playlists.
	again := createPlaylist(t, handler, token, "Favoriten")
	if again.ID == first.ID {
		t.Errorf("the same name returned the same playlist id %d", again.ID)
	}

	// The songs are not in the list answer: a client shows playlists, not every song
	// of every playlist. The answer has no song list, so nothing here can be longer
	// than the fields of one playlist.
	for _, p := range playlists {
		if p.SongCount < 0 {
			t.Errorf("song_count is negative: %v", p)
		}
	}
}

// TestAddPlaylistSong checks that a song is added at the end, that the same song twice
// is allowed (a playlist is an order, not a set), and that both unknown references are
// refused with the message that names which one is missing.
func TestAddPlaylistSong(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))

	playlist := createPlaylist(t, handler, token, "Favoriten")

	one := uploadTrack(t, upload, token, "eins.wav")
	two := uploadTrack(t, upload, token, "zwei.wav")

	rec := postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": `+itoa(two.ID)+`}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("add -> %d (%s)", rec.Code, rec.Body)
	}
	var song PlaylistSong
	if err := json.Unmarshal(rec.Body.Bytes(), &song); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if song.Position != 1 || song.TrackID != two.ID || song.Title != two.Title {
		t.Errorf("first song answered %v, wanted position 1 with the title from the library", song)
	}

	// The same song twice is allowed: positions differ.
	rec = postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": `+itoa(two.ID)+`}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("the same song twice -> %d (%s), wanted 201", rec.Code, rec.Body)
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &song); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if song.Position != 2 {
		t.Errorf("second add answered position %d, wanted 2", song.Position)
	}

	rec = postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": 9999}`)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "song is not in the library") {
		t.Errorf("unknown track -> %d (%s), wanted 404 naming the song", rec.Code, rec.Body)
	}

	rec = postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": 0}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "track_id must be a positive number") {
		t.Errorf("track_id 0 -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	rec = postJSON(t, handler, "/api/playlists/0/songs", token, `{"track_id": `+itoa(one.ID)+`}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "must be a positive number") {
		t.Errorf("playlist id 0 -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// An unknown field in the body is refused, as the register endpoint does.
	rec = postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": 1, "position": 3}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "one JSON object") {
		t.Errorf("unknown field -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// The cap is a real limit, not a silent drop.
	for i := 0; i < maxPlaylistSongs; i++ {
		if _, err := db.Exec(`INSERT INTO playlist_song (playlist_id, track_id, position, added_at) VALUES (?, ?, ?, ?)`,
			playlist.ID, two.ID, i+1, 1); err != nil {
			t.Fatalf("insert row %d: %v", i+1, err)
		}
	}
	rec = postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{`+`"track_id": `+itoa(two.ID)+`}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "holds at most 200 songs") {
		t.Errorf("adding past the cap -> %d (%s), wanted 400 naming the cap", rec.Code, rec.Body)
	}
}

// TestPlaylistPositionTooLarge: digits that do not fit an int64 are answered as too large,
// not as an empty slot. The position stays an int64 through the path, so a 32-bit build
// does not answer about a wrapped slot.
func TestPlaylistPositionTooLarge(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	playlist := createPlaylist(t, handler, token, "Favoriten")

	rec := deleteRequest(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs/9223372036854775808", token)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "position is too large") {
		t.Errorf("position past int64 -> %d (%s), wanted 400 saying it is too large", rec.Code, rec.Body)
	}

	rec = deleteRequest(t, handler, "/api/playlists/9223372036854775808", token)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "playlist id is too large") {
		t.Errorf("playlist id past int64 -> %d (%s), wanted 400 saying it is too large", rec.Code, rec.Body)
	}
}

// TestRemoveSongRenumbers is the promise the endpoint makes: the positions a client
// sees stay 1..n with no gaps, so a slot can be addressed without knowing the history.
func TestRemoveSongRenumbers(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))

	playlist := createPlaylist(t, handler, token, "Favoriten")
	ids := []int64{}
	for _, name := range []string{"eins.wav", "zwei.wav", "drei.wav"} {
		track := uploadTrack(t, upload, token, name)
		ids = append(ids, track.ID)
		postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": `+itoa(track.ID)+`}`)
	}

	rec := deleteRequest(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs/2", token)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("remove -> %d (%s), wanted 204", rec.Code, rec.Body)
	}
	if rec.Body.Len() != 0 {
		t.Errorf("a 204 must have no body, got %s", rec.Body)
	}
	if rec.Header().Get("Content-Type") != "" {
		t.Errorf("a 204 must not claim a content type, got %q", rec.Header().Get("Content-Type"))
	}

	rec = get(t, handler, "/api/playlists/"+itoa(playlist.ID), token)
	var withSongs PlaylistWithSongs
	if err := json.Unmarshal(rec.Body.Bytes(), &withSongs); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(withSongs.Songs) != 2 {
		t.Fatalf("after the remove the playlist has %d songs, wanted 2 (%s)", len(withSongs.Songs), rec.Body)
	}
	if withSongs.Songs[0].Position != 1 || withSongs.Songs[1].Position != 2 {
		t.Errorf("positions after a remove are not 1..n: %s", rec.Body)
	}
	if withSongs.Songs[0].TrackID != ids[0] || withSongs.Songs[1].TrackID != ids[2] {
		t.Errorf("the wrong songs are left: %s", rec.Body)
	}
	if withSongs.SongCount != 2 {
		t.Errorf("song_count says %d after a remove, wanted 2", withSongs.SongCount)
	}

	rec = deleteRequest(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs/3", token)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "no song at position 3") {
		t.Errorf("empty slot -> %d (%s), wanted 404 naming the position", rec.Code, rec.Body)
	}

	rec = deleteRequest(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs/-1", token)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "position must be a positive number") {
		t.Errorf("position -1 -> %d (%s), wanted 400", rec.Code, rec.Body)
	}
}

// TestDeletePlaylistKeepsTheLibrary: deleting a list of references must not delete the
// files or the library rows.
func TestDeletePlaylistKeepsTheLibrary(t *testing.T) {
	db := openTestDB(t)
	handler := playlistMux(db, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))

	playlist := createPlaylist(t, handler, token, "Favoriten")
	track := uploadTrack(t, upload, token, "lied.wav")
	postJSON(t, handler, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": `+itoa(track.ID)+`}`)

	rec := deleteRequest(t, handler, "/api/playlists/"+itoa(playlist.ID), token)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete -> %d (%s), wanted 204", rec.Code, rec.Body)
	}

	// The song is still in the library, and the playlist is gone.
	library := musicMux(db, t.TempDir(), newRateLimiter(100, time.Second))
	rec = get(t, library, "/api/music", token)
	if !strings.Contains(rec.Body.String(), `"title":"lied.wav"`) {
		t.Errorf("the song is not in the library after its playlist was deleted: %s", rec.Body)
	}

	rec = get(t, handler, "/api/playlists", token)
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("the playlist is still listed: %s", rec.Body)
	}

	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM playlist_song WHERE playlist_id = ?`, playlist.ID).Scan(&count); err != nil {
		t.Fatalf("count the rows: %v", err)
	}
	if count != 0 {
		t.Errorf("%d song rows are left for a deleted playlist", count)
	}
}

// TestPlaylistBucketsAreSeparate: a client that builds a playlist should not be able to
// stop reading the library, and the queue has its own bucket.
func TestPlaylistBucketsAreSeparate(t *testing.T) {
	db := openTestDB(t)
	token := testToken(t, db, "lukas")

	playlistFull := playlistMux(db, newRateLimiter(2, time.Second))
	listOpen := musicMux(db, t.TempDir(), newRateLimiter(2, time.Second))
	queueOpen := queueMux(db, newRateLimiter(2, time.Second))

	for i := 0; i < 2; i++ {
		rec := get(t, playlistFull, "/api/playlists", token)
		if rec.Code != http.StatusOK {
			t.Fatalf("playlist %d -> %d (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := get(t, playlistFull, "/api/playlists", token)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third playlist request -> %d (%s), wanted 429", rec.Code, rec.Body)
	}
	checkRetryAfter(t, rec, 1)

	rec = get(t, listOpen, "/api/music", token)
	if rec.Code != http.StatusOK {
		t.Errorf("a full playlist bucket stopped the library -> %d (%s)", rec.Code, rec.Body)
	}

	rec = get(t, queueOpen, "/api/queue", token)
	if rec.Code != http.StatusOK {
		t.Errorf("a full playlist bucket stopped the queue -> %d (%s)", rec.Code, rec.Body)
	}
}
