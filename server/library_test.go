package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// libraryRoutes is the pair main.go mounts, so the {id} pattern is part of the test
// rather than assumed.
func libraryRoutes(db *sql.DB, library string) http.Handler {
	mux := http.NewServeMux()
	limiter := newRateLimiter(100, time.Second)
	mux.HandleFunc("GET /api/music", libraryHandler(db, limiter))
	mux.HandleFunc("GET /api/music/{id}", trackFileHandler(db, library, limiter))
	return mux
}

func get(t *testing.T, handler http.Handler, token, path string) *httptest.ResponseRecorder {
	t.Helper()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	handler.ServeHTTP(rec, req)
	return rec
}

// TestLibraryRequiresAuth is the rule for a read endpoint: an anonymous caller gets
// the same two 401 answers as GET /api/session.
func TestLibraryRequiresAuth(t *testing.T) {
	db := openTestDB(t)
	handler := libraryRoutes(db, t.TempDir())
	token := testToken(t, db, "lukas")

	rec := get(t, handler, "", "/api/music")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous list -> %d, wanted 401 (%s)", rec.Code, rec.Body)
	}
	if !strings.Contains(rec.Body.String(), "authorization header") {
		t.Errorf("missing header must use the missing-header message: %s", rec.Body)
	}

	rec = get(t, handler, "not-a-known-token", "/api/music/1")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unknown token -> %d, wanted 401 (%s)", rec.Code, rec.Body)
	}
	if !strings.Contains(rec.Body.String(), "session is not valid or expired") {
		t.Errorf("unknown token must use the session message: %s", rec.Body)
	}

	// A valid token is the path these messages are compared against.
	if rec = get(t, handler, token, "/api/music"); rec.Code != http.StatusOK {
		t.Fatalf("logged-in list -> %d (%s)", rec.Code, rec.Body)
	}
}

// An empty library answers [], never null: the client tells an empty library and an
// unreadable answer apart.
func TestLibraryAnswersEmptyLibraryAsList(t *testing.T) {
	db := openTestDB(t)
	handler := libraryRoutes(db, t.TempDir())
	token := testToken(t, db, "lukas")

	rec := get(t, handler, token, "/api/music")
	if rec.Code != http.StatusOK {
		t.Fatalf("list -> %d (%s)", rec.Code, rec.Body)
	}
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("an empty library must answer [], got %s", rec.Body)
	}
}

// The library is shared, so a list shows what every user uploaded and names who
// uploaded it. Rows come in the order they were added, which is what the client's
// "Hinzugefügt am" sort uses.
func TestLibraryListsEveryUploadedTrack(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	handler := uploadHandler(db, library, newRateLimiter(100, time.Second))

	lukas := testToken(t, db, "lukas")
	nina := testToken(t, db, "nina")

	first := uploadFile(t, handler, lukas, "file", "Mein Song.mp3", taggedMP3())
	second := uploadFile(t, handler, nina, "file", "anderer.wav", tinyWAV())
	if first.Code != http.StatusCreated || second.Code != http.StatusCreated {
		t.Fatalf("uploads -> %d %d", first.Code, second.Code)
	}

	rec := get(t, libraryRoutes(db, library), nina, "/api/music")
	if rec.Code != http.StatusOK {
		t.Fatalf("list -> %d (%s)", rec.Code, rec.Body)
	}

	var rows []Track
	if err := json.Unmarshal(rec.Body.Bytes(), &rows); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("list has %d rows, wanted 2 (%s)", len(rows), rec.Body)
	}

	if rows[0].ID != 1 || rows[0].Uploader != "lukas" || rows[0].Title != "Neutrone (Remix)" || rows[0].Artist != "Kraftwerk" {
		t.Errorf("first row is not the documented track: %+v", rows[0])
	}
	// The duration is what the file said: 10 frames at 32000 Hz. The second row has
	// none, because a WAV container cannot be measured here.
	if rows[0].DurationMS != 360 {
		t.Errorf("first row duration is %d, wanted 360", rows[0].DurationMS)
	}
	if rows[1].ID != 2 || rows[1].Uploader != "nina" || rows[1].Artist != "" || rows[1].DurationMS != 0 {
		t.Errorf("second row is not the documented track: %+v", rows[1])
	}

	// Every row points at a file that is really in the library folder.
	for _, row := range rows {
		if _, err := os.Stat(filepath.Join(library, row.StoredName)); err != nil {
			t.Errorf("row %d points at a file that is not there: %v", row.ID, err)
		}
	}
}

// A bad id is a bad request, an unknown one is a 404 in the JSON error shape, and a
// row whose file is gone is not served quietly as an empty file.
func TestTrackFileAnswers(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	handler := uploadHandler(db, library, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")
	routes := libraryRoutes(db, library)

	rec := uploadFile(t, handler, token, "file", "song.mp3", taggedMP3())
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload -> %d (%s)", rec.Code, rec.Body)
	}
	var track Track
	if err := json.Unmarshal(rec.Body.Bytes(), &track); err != nil {
		t.Fatalf("decode upload: %v", err)
	}

	rec = get(t, routes, token, "/api/music/"+strconv.FormatInt(track.ID, 10))
	if rec.Code != http.StatusOK {
		t.Fatalf("file -> %d (%s)", rec.Code, rec.Body)
	}
	if rec.Body.String() != string(taggedMP3()) {
		t.Errorf("the body is not the stored file")
	}
	if rec.Header().Get("Content-Type") != "audio/mpeg" {
		t.Errorf("Content-Type is %q, wanted the type recorded on the row", rec.Header().Get("Content-Type"))
	}
	if rec.Header().Get("Accept-Ranges") != "bytes" {
		t.Errorf("a player needs to know the file can be read in parts")
	}

	// The download header is http.ServeFile's own rather than this handler's, and
	// api-docs.md documents it for the file and for a part of it.
	if disp := rec.Header().Get("Content-Disposition"); !strings.HasPrefix(disp, `inline; filename="`) {
		t.Errorf("Content-Disposition is %q, wanted what api-docs.md documents", disp)
	}

	// A player that asks for part of the file gets exactly that part.
	rec = getRange(t, routes, token, strconv.FormatInt(track.ID, 10), "bytes=0-3")
	if rec.Code != http.StatusPartialContent || rec.Body.String() != string(taggedMP3()[:4]) {
		t.Errorf("range request -> %d (%s), wanted 206 with the first four bytes", rec.Code, rec.Body)
	}

	// A range outside the file is answered by http.ServeFile itself, in plain text,
	// which is the one answer on this route that is not the JSON error shape.
	rec = getRange(t, routes, token, strconv.FormatInt(track.ID, 10), "bytes=99999-100000")
	if rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("range outside the file -> %d (%s), wanted 416", rec.Code, rec.Body)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/plain") {
		t.Errorf("the 416 answer is %q, but api-docs.md says plain text, not the JSON shape", ct)
	}
	if cr := rec.Header().Get("Content-Range"); cr != "bytes */"+strconv.Itoa(len(taggedMP3())) {
		t.Errorf("Content-Range is %q, wanted the whole size after the slash", cr)
	}

	rec = get(t, routes, token, "/api/music/99")
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "no song with that id") {
		t.Errorf("unknown id -> %d (%s), wanted 404 with the JSON error shape", rec.Code, rec.Body)
	}

	rec = get(t, routes, token, "/api/music/not-a-number")
	if rec.Code != http.StatusBadRequest {
		t.Errorf("bad id -> %d (%s), wanted 400", rec.Code, rec.Body)
	}

	// A row that points at a file the library no longer has.
	gone := uploadFile(t, handler, token, "file", "gone.mp3", taggedMP3())
	var goneTrack Track
	if err := json.Unmarshal(gone.Body.Bytes(), &goneTrack); err != nil {
		t.Fatalf("decode upload: %v", err)
	}
	if err := os.Remove(filepath.Join(library, goneTrack.StoredName)); err != nil {
		t.Fatalf("remove the file: %v", err)
	}
	rec = get(t, routes, token, "/api/music/"+strconv.FormatInt(goneTrack.ID, 10))
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "not in the library") {
		t.Errorf("missing file -> %d (%s), wanted 404 with the JSON error shape", rec.Code, rec.Body)
	}
}

func getRange(t *testing.T, handler http.Handler, token, id, rng string) *httptest.ResponseRecorder {
	t.Helper()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/music/"+id, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Range", rng)
	handler.ServeHTTP(rec, req)
	return rec
}

// The library bucket is its own: a client that keeps opening the library screen must
// not starve the login or registration buckets. The file route shares it, so one
// address cannot read the library and stream songs without limit.
func TestLibraryRateLimit(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	limiter := newRateLimiter(2, time.Second)
	token := testToken(t, db, "lukas")

	for i := 0; i < 2; i++ {
		rec := get(t, libraryHandler(db, limiter), token, "/api/music")
		if rec.Code != http.StatusOK {
			t.Fatalf("list %d -> %d (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := get(t, libraryHandler(db, limiter), token, "/api/music")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third list -> %d, wanted 429 (%s)", rec.Code, rec.Body)
	}
	checkRetryAfter(t, rec, 1)

	rec = get(t, trackFileHandler(db, library, limiter), token, "/api/music/1")
	if rec.Code != http.StatusTooManyRequests {
		t.Errorf("the file route must use the same library bucket -> %d (%s)", rec.Code, rec.Body)
	}
}

// A table created before the metadata columns existed is not changed by CREATE TABLE
// IF NOT EXISTS, so the columns have to be added for an existing saphire.db.
func TestEnsureTrackColumnsAddsMissingColumns(t *testing.T) {
	db := openTestDB(t)

	if _, err := db.Exec(`DROP TABLE track`); err != nil {
		t.Fatalf("drop table: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE track (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		user_id INTEGER NOT NULL REFERENCES user(id),
		title TEXT NOT NULL,
		stored_name TEXT NOT NULL UNIQUE,
		size INTEGER NOT NULL,
		content_type TEXT NOT NULL,
		uploaded_at INTEGER NOT NULL
	)`); err != nil {
		t.Fatalf("create the old table: %v", err)
	}

	// An old row must survive and read as an untagged file, not fail.
	res, err := db.Exec(`INSERT INTO user (username, password_hash) VALUES ('lukas', 'not-a-bcrypt-hash')`)
	if err != nil {
		t.Fatalf("insert a user: %v", err)
	}
	userID, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("last insert id: %v", err)
	}
	res, err = db.Exec(`INSERT INTO track (user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?, 'alt.mp3', 'old', 1, 'audio/mpeg', 0)`, userID)
	if err != nil {
		t.Fatalf("insert an old row: %v", err)
	}
	// The id is read from the insert, not assumed: the test must not pass because both
	// rows happened to be the first ones.
	trackID, err := res.LastInsertId()
	if err != nil {
		t.Fatalf("last insert id: %v", err)
	}

	if err := ensureTrackColumns(db); err != nil {
		t.Fatalf("add the columns: %v", err)
	}

	track, err := trackByID(db, trackID)
	if err != nil {
		t.Fatalf("read the old row: %v", err)
	}
	if track.Artist != "" || track.DurationMS != 0 {
		t.Errorf("an old row read as %+v, wanted the empty defaults", track)
	}

	// Running it again does not add a column twice.
	if err := ensureTrackColumns(db); err != nil {
		t.Fatalf("add the columns again: %v", err)
	}
}
