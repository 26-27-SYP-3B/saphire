package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"
)

func queueMux(db *sql.DB, limiter *rateLimiter) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/queue", fillQueueHandler(db, limiter))
	mux.HandleFunc("GET /api/queue", getQueueHandler(db, limiter))
	mux.HandleFunc("POST /api/queue/songs", appendQueueEntryHandler(db, limiter))
	mux.HandleFunc("DELETE /api/queue/{position}", removeQueueEntryHandler(db, limiter))
	mux.HandleFunc("DELETE /api/queue", clearQueueHandler(db, limiter))
	return mux
}

// readQueue reads a GET /api/queue answer as a client would.
func readQueue(t *testing.T, handler http.Handler, token string) []QueueEntry {
	t.Helper()

	rec := get(t, handler, "/api/queue", token)
	if rec.Code != http.StatusOK {
		t.Fatalf("queue -> %d (%s)", rec.Code, rec.Body)
	}

	var entries []QueueEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	return entries
}

func TestQueueRequiresAuth(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))

	rec := get(t, handler, "/api/queue", "")
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "authorization header") {
		t.Errorf("anonymous queue -> %d (%s), wanted 401 with the missing-header message", rec.Code, rec.Body)
	}

	rec = postJSON(t, handler, "/api/queue", "not-a-known-token", `{"source": "library"}`)
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "session is not valid or expired") {
		t.Errorf("unknown token -> %d (%s), wanted 401 with the session message", rec.Code, rec.Body)
	}
}

// TestQueueIsOnlySongsAndOrder is the design point: the queue stores which songs in
// which order and nothing about what filled it. A playlist is one source, so a plain
// queue feature later is another source, not a different queue.
func TestQueueIsOnlySongsAndOrder(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	playlists := playlistMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	// A source name the queue does not know is refused with the names it does know.
	rec := postJSON(t, handler, "/api/queue", token, `{"source": "search"}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `source must be`) {
		t.Errorf("unknown source -> %d (%s), wanted 400 naming the sources", rec.Code, rec.Body)
	}

	// The whole library needs no source_id; sending one is not silently ignored.
	rec = postJSON(t, handler, "/api/queue", token, `{"source": "library", "source_id": 4}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "source_id is not used for the whole library") {
		t.Errorf("source_id with library -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// A source that names something needs a real id.
	rec = postJSON(t, handler, "/api/queue", token, `{"source": "playlist", "source_id": 0}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "source_id must be a positive number") {
		t.Errorf("source_id 0 -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// An empty playlist fills an empty queue. That is what an empty playlist means,
	// and it is not an error.
	playlist := createPlaylist(t, playlists, token, "Leer")
	rec = postJSON(t, handler, "/api/queue", token, `{"source": "playlist", "source_id": `+itoa(playlist.ID)+`}`)
	if rec.Code != http.StatusOK || strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("fill from an empty playlist -> %d (%s), wanted 200 with []", rec.Code, rec.Body)
	}

	// An entry has position, track_id and title and nothing else. There is no field
	// that could say what filled the queue, so any source produces the same shape.
	track := uploadTrack(t, upload, token, "lied.wav")
	postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)

	rec = get(t, handler, "/api/queue", token)
	var raw []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(raw) != 1 {
		t.Fatalf("queue has %d entries, wanted 1 (%s)", len(raw), rec.Body)
	}
	keys := make([]string, 0, len(raw[0]))
	for k := range raw[0] {
		keys = append(keys, k)
	}
	if len(keys) != 3 {
		t.Errorf("an entry carries %v, wanted exactly position, track_id and title", keys)
	}
	for _, key := range keys {
		if key != "position" && key != "track_id" && key != "title" {
			t.Errorf("an entry carries the field %q, which would record where it came from", key)
		}
	}
}

// TestFillFromPlaylistKeepsThePlaylistOrder: a queue is filled in the order the source
// gives, which for a playlist is its positions, not the library order.
func TestFillFromPlaylistKeepsThePlaylistOrder(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	playlists := playlistMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	playlist := createPlaylist(t, playlists, token, "Favoriten")
	first := uploadTrack(t, upload, token, "eins.wav")
	second := uploadTrack(t, upload, token, "zwei.wav")

	// The playlist order is the second song first, so the queue must follow it.
	postJSON(t, playlists, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": `+itoa(second.ID)+`}`)
	postJSON(t, playlists, "/api/playlists/"+itoa(playlist.ID)+"/songs", token, `{"track_id": `+itoa(first.ID)+`}`)

	rec := postJSON(t, handler, "/api/queue", token, `{"source": "playlist", "source_id": `+itoa(playlist.ID)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("fill from playlist -> %d (%s)", rec.Code, rec.Body)
	}

	var entries []QueueEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("queue has %d entries, wanted 2 (%s)", len(entries), rec.Body)
	}
	if entries[0].TrackID != second.ID || entries[1].TrackID != first.ID {
		t.Errorf("the queue is not in the playlist order: %s", rec.Body)
	}
	if entries[0].Position != 1 || entries[1].Position != 2 {
		t.Errorf("the queue positions are not 1..n: %s", rec.Body)
	}

	// Only the caller's own playlist can fill a queue.
	other := testToken(t, db, "andere")
	rec = postJSON(t, handler, "/api/queue", other, `{"source": "playlist", "source_id": `+itoa(playlist.ID)+`}`)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "not in your playlists") {
		t.Errorf("other user filling from it -> %d (%s), wanted 404 with the ownership message", rec.Code, rec.Body)
	}
}

// TestFillReplacesTheQueue: filling is not adding. A player that starts a second
// playlist must not keep the songs of the first.
func TestFillReplacesTheQueue(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	playlists := playlistMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	one := uploadTrack(t, upload, token, "eins.wav")
	two := uploadTrack(t, upload, token, "zwei.wav")

	first := createPlaylist(t, playlists, token, "erste")
	second := createPlaylist(t, playlists, token, "zweite")
	postJSON(t, playlists, "/api/playlists/"+itoa(first.ID)+"/songs", token, `{"track_id": `+itoa(one.ID)+`}`)
	postJSON(t, playlists, "/api/playlists/"+itoa(second.ID)+"/songs", token, `{"track_id": `+itoa(two.ID)+`}`)

	postJSON(t, handler, "/api/queue", token, `{"source": "playlist", "source_id": `+itoa(first.ID)+`}`)
	postJSON(t, handler, "/api/queue", token, `{"source": "playlist", "source_id": `+itoa(second.ID)+`}`)

	entries := readQueue(t, handler, token)
	if len(entries) != 1 || entries[0].TrackID != two.ID {
		t.Errorf("the second fill did not replace the first: %v", entries)
	}

	// A single song is a source too, which is what "play this now" needs.
	rec := postJSON(t, handler, "/api/queue", token, `{"source": "track", "source_id": `+itoa(one.ID)+`}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("fill from one song -> %d (%s)", rec.Code, rec.Body)
	}

	var single []QueueEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &single); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(single) != 1 || single[0].TrackID != one.ID || single[0].Position != 1 {
		t.Errorf("one song as a source answered %v", single)
	}

	// The whole library is the third source, ordered by id.
	rec = postJSON(t, handler, "/api/queue", token, `{"source": "library"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("fill from the library -> %d (%s)", rec.Code, rec.Body)
	}
	var library []QueueEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &library); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(library) != 2 || library[0].TrackID != one.ID || library[1].TrackID != two.ID {
		t.Errorf("the library source answered %v, wanted both songs by id", library)
	}
}

// TestFillFromUnknownTrackNamesTheSong: a source that names one song cannot be an empty
// list. Answering 200 with [] here would also wipe the queue that was there, so the
// refusal has to happen before anything is deleted.
func TestFillFromUnknownTrackNamesTheSong(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	track := uploadTrack(t, upload, token, "lied.wav")
	postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)

	rec := postJSON(t, handler, "/api/queue", token, `{"source": "track", "source_id": 9999}`)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "song is not in the library") {
		t.Errorf("unknown song as a source -> %d (%s), wanted 404 naming the song", rec.Code, rec.Body)
	}

	entries := readQueue(t, handler, token)
	if len(entries) != 1 || entries[0].TrackID != track.ID {
		t.Errorf("the failed fill left %v, wanted the queue as it was before", entries)
	}
}

// TestAppendQueueEntry is the plain queue feature on the server side: add one song at
// the end without a source, and the limit is a real limit rather than a silent drop.
func TestAppendQueueEntry(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	track := uploadTrack(t, upload, token, "lied.wav")

	rec := postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("append -> %d (%s)", rec.Code, rec.Body)
	}

	var entry QueueEntry
	if err := json.Unmarshal(rec.Body.Bytes(), &entry); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if entry.Position != 1 || entry.TrackID != track.ID || entry.Title != track.Title {
		t.Errorf("append answered %v, wanted position 1 with the title from the library", entry)
	}

	// The same song twice is allowed, because a queue is an order, not a set.
	rec = postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("the same song twice -> %d (%s), wanted 201", rec.Code, rec.Body)
	}

	rec = postJSON(t, handler, "/api/queue/songs", token, `{"track_id": 9999}`)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "song is not in the library") {
		t.Errorf("unknown track -> %d (%s), wanted 404 naming the song", rec.Code, rec.Body)
	}

	// A body that is not one object with track_id, and a body over the limit, are
	// refused the same way as the register endpoint.
	rec = postJSON(t, handler, "/api/queue/songs", token, `{"track_id": 1} {"track_id": 2}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "exactly one JSON object") {
		t.Errorf("two objects -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	for i := 0; i < maxQueueEntries; i++ {
		if _, err := db.Exec(`INSERT INTO queue_entry (user_id, position, track_id, added_at) VALUES (?, ?, ?, ?)`,
			testUserID(t, db, "lukas"), i+1, track.ID, 1); err != nil {
			t.Fatalf("insert row %d: %v", i+1, err)
		}
	}

	rec = postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "holds at most 200 songs") {
		t.Errorf("adding past the cap -> %d (%s), wanted 400 naming the cap", rec.Code, rec.Body)
	}
}

// TestFillPastTheCapKeepsTheQueue: a source with more songs than a queue holds is refused
// and the queue stays as it was — a fill that is refused must not leave half of it. The
// cap is read with the query, so a library larger than a queue is not copied into memory
// only to be refused.
func TestFillPastTheCapKeepsTheQueue(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	user := testToken(t, db, "lukas")

	track := uploadTrack(t, upload, user, "lied.wav")
	userID := testUserID(t, db, "lukas")

	for i := 0; i < maxQueueEntries; i++ {
		if _, err := db.Exec(`INSERT INTO track (user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?, ?, ?, ?, ?, ?)`,
			userID, "song", "row-"+itoa(int64(i)), 1, "audio/wav", 1); err != nil {
			t.Fatalf("insert row %d: %v", i+1, err)
		}
	}

	postJSON(t, handler, "/api/queue/songs", user, `{"track_id": `+itoa(track.ID)+`}`)

	rec := postJSON(t, handler, "/api/queue", user, `{"source": "library"}`)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "holds at most 200 songs") {
		t.Errorf("filling past the cap -> %d (%s), wanted 400 naming the cap", rec.Code, rec.Body)
	}

	entries := readQueue(t, handler, user)
	if len(entries) != 1 || entries[0].TrackID != track.ID {
		t.Errorf("the refused fill left %v, wanted the queue as it was", entries)
	}
}

// TestRemoveQueueEntryRenamesPositions — the same promise as a playlist: positions stay
// 1..n with no gaps, and an empty slot names the position it was asked about.
func TestRemoveQueueEntryRenamesPositions(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	ids := []int64{}
	for _, name := range []string{"eins.wav", "zwei.wav", "drei.wav"} {
		track := uploadTrack(t, upload, token, name)
		ids = append(ids, track.ID)
		postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)
	}

	rec := deleteRequest(t, handler, "/api/queue/2", token)
	if rec.Code != http.StatusNoContent || rec.Body.Len() != 0 {
		t.Fatalf("remove -> %d (%s), wanted 204 with no body", rec.Code, rec.Body)
	}

	entries := readQueue(t, handler, token)
	if len(entries) != 2 || entries[0].Position != 1 || entries[1].Position != 2 {
		t.Fatalf("positions after a remove are not 1..n: %v", entries)
	}
	if entries[0].TrackID != ids[0] || entries[1].TrackID != ids[2] {
		t.Errorf("the wrong songs are left: %v", entries)
	}

	rec = deleteRequest(t, handler, "/api/queue/3", token)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "no song at position 3 in this queue") {
		t.Errorf("empty slot -> %d (%s), wanted 404 naming the position and the queue", rec.Code, rec.Body)
	}

	rec = deleteRequest(t, handler, "/api/queue/+3", token)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "position must be a positive number") {
		t.Errorf("position +3 -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// Digits that do not fit an int64 are answered as too large. The position is kept as
	// an int64 through the whole path, so a 32-bit build does not answer about a wrapped
	// slot instead.
	rec = deleteRequest(t, handler, "/api/queue/9223372036854775808", token)
	if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "position is too large") {
		t.Errorf("position past int64 -> %d (%s), wanted 400 saying it is too large", rec.Code, rec.Body)
	}

	// A queue is per user: another user's queue is not touched.
	other := testToken(t, db, "andere")
	entries = readQueue(t, handler, other)
	if len(entries) != 0 {
		t.Errorf("the other user sees %d entries, wanted none", len(entries))
	}
}

func TestClearQueue(t *testing.T) {
	db := openTestDB(t)
	handler := queueMux(db, newRateLimiter(100, time.Second))
	upload := uploadHandler(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	track := uploadTrack(t, upload, token, "lied.wav")
	postJSON(t, handler, "/api/queue/songs", token, `{"track_id": `+itoa(track.ID)+`}`)

	rec := deleteRequest(t, handler, "/api/queue", token)
	if rec.Code != http.StatusNoContent || rec.Body.Len() != 0 {
		t.Fatalf("clear -> %d (%s), wanted 204 with no body", rec.Code, rec.Body)
	}

	entries := readQueue(t, handler, token)
	if len(entries) != 0 {
		t.Errorf("the queue is not empty after a clear: %v", entries)
	}

	// The song is still in the library: a queue holds references, not files.
	library := musicMux(db, t.TempDir(), newRateLimiter(100, time.Second))
	rec = get(t, library, "/api/music", token)
	if !strings.Contains(rec.Body.String(), `"title":"lied.wav"`) {
		t.Errorf("the song is gone from the library after the queue was cleared: %s", rec.Body)
	}
}

// TestQueueAndPlaylistBucketsAreSeparate checks both directions with two limiter
// instances the way main.go wires them — that is also all this test can prove, since a
// shared instance would fail here.
func TestQueueAndPlaylistBucketsAreSeparate(t *testing.T) {
	db := openTestDB(t)
	token := testToken(t, db, "lukas")

	queueFull := queueMux(db, newRateLimiter(2, time.Second))
	playlistOpen := playlistMux(db, newRateLimiter(2, time.Second))

	for i := 0; i < 2; i++ {
		rec := get(t, queueFull, "/api/queue", token)
		if rec.Code != http.StatusOK {
			t.Fatalf("queue %d -> %d (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := get(t, queueFull, "/api/queue", token)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third queue request -> %d (%s), wanted 429", rec.Code, rec.Body)
	}
	checkRetryAfter(t, rec, 1)

	rec = get(t, playlistOpen, "/api/playlists", token)
	if rec.Code != http.StatusOK {
		t.Errorf("a full queue bucket stopped the playlists -> %d (%s)", rec.Code, rec.Body)
	}

	// The other way round: a full playlist bucket must not stop a player reading its
	// queue.
	playlistFull := playlistMux(db, newRateLimiter(2, time.Second))
	queueOpen := queueMux(db, newRateLimiter(2, time.Second))

	for i := 0; i < 3; i++ {
		rec = get(t, playlistFull, "/api/playlists", token)
	}
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third playlist request -> %d (%s), wanted 429", rec.Code, rec.Body)
	}

	rec = get(t, queueOpen, "/api/queue", token)
	if rec.Code != http.StatusOK {
		t.Errorf("a full playlist bucket stopped the queue -> %d (%s)", rec.Code, rec.Body)
	}
}

// testUserID reads the id a test user got, so a test can insert rows the way the
// endpoint would.
func testUserID(t *testing.T, db *sql.DB, username string) int64 {
	t.Helper()

	user, err := GetUserByUsername(db, username)
	if err != nil {
		t.Fatalf("load the user: %v", err)
	}
	return user.ID
}
