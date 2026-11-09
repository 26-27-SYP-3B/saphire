package main

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// testToken registers a user and returns the session token it gets, so the
// upload tests work with a real session instead of a hand-made one.
func testToken(t *testing.T, db *sql.DB, username string) string {
	t.Helper()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader(`{"username": "`+username+`", "password": "valid-password"}`))
	registerHandler(db, newRateLimiter(100, time.Second)).ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register %s -> %d (%s)", username, rec.Code, rec.Body)
	}

	rec = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username": "`+username+`", "password": "valid-password"}`))
	loginHandler(db, newRateLimiter(100, time.Second)).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("login %s -> %d (%s)", username, rec.Code, rec.Body)
	}

	var login struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &login); err != nil {
		t.Fatalf("decode login answer: %v", err)
	}
	return login.Token
}

// uploadFile sends one multipart upload. fileName == "" sends the field as a
// plain form value; field == "" sends an empty multipart body.
func uploadFile(t *testing.T, handler http.HandlerFunc, token, field, fileName string, content []byte) *httptest.ResponseRecorder {
	t.Helper()

	var body bytes.Buffer
	w := multipart.NewWriter(&body)
	switch {
	case field == "":
		// nothing at all
	case fileName == "":
		if err := w.WriteField(field, "not a file"); err != nil {
			t.Fatalf("write field: %v", err)
		}
	default:
		part, err := w.CreateFormFile(field, fileName)
		if err != nil {
			t.Fatalf("create form file: %v", err)
		}
		if _, err := part.Write(content); err != nil {
			t.Fatalf("write part: %v", err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close multipart body: %v", err)
	}

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/music/upload", &body)
	req.Header.Set("Content-Type", w.FormDataContentType())
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	handler.ServeHTTP(rec, req)
	return rec
}

// tinyWAV is the smallest recognizable audio file: a RIFF/WAVE header plus four samples.
func tinyWAV() []byte {
	return []byte("RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00data\x04\x00\x00\x00\x00\x00\x00\x00")
}

// notAudio is binary content that no audio format can claim.
var notAudio = []byte{1, 2, 3, 4, 5, 6, 7, 8}

// TestOpenLibrary checks that the server creates the folder it saves songs in.
func TestOpenLibrary(t *testing.T) {
	t.Setenv("SAPHIRE_LIBRARY_PATH", filepath.Join(t.TempDir(), "library"))

	dir, err := OpenLibrary()
	if err != nil {
		t.Fatalf("open library: %v", err)
	}
	info, err := os.Stat(dir)
	if err != nil {
		t.Fatalf("the library folder must exist: %v", err)
	}
	if !info.IsDir() {
		t.Errorf("%s is not a folder", dir)
	}

	// A second call on an existing folder is fine, the server starts repeatedly.
	if _, err := OpenLibrary(); err != nil {
		t.Fatalf("open the library again: %v", err)
	}
}

// TestUploadRequiresAuth is the rule this endpoint exists for: nobody who is not
// logged in may put anything into the shared library.
func TestUploadRequiresAuth(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	handler := uploadHandler(db, library, newRateLimiter(100, time.Second))

	rec := uploadFile(t, handler, "", "file", "song.wav", tinyWAV())
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous upload -> %d, wanted 401 (%s)", rec.Code, rec.Body)
	}
	if !strings.Contains(rec.Body.String(), "authorization header") {
		t.Errorf("missing header must use the missing-header message: %s", rec.Body)
	}

	rec = uploadFile(t, handler, "not-a-known-token", "file", "song.wav", tinyWAV())
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unknown token -> %d, wanted 401 (%s)", rec.Code, rec.Body)
	}
	if !strings.Contains(rec.Body.String(), "session is not valid or expired") {
		t.Errorf("unknown token must use the session message: %s", rec.Body)
	}

	// Nothing was stored for the refused requests.
	entries, err := os.ReadDir(library)
	if err != nil {
		t.Fatalf("read library: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("a refused upload wrote a file: %v", entries)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM track`).Scan(&count); err != nil {
		t.Fatalf("count tracks: %v", err)
	}
	if count != 0 {
		t.Errorf("a refused upload saved a track row")
	}
}

func TestUploadSavesToSharedLibrary(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	handler := uploadHandler(db, library, newRateLimiter(100, time.Second))

	lukas := testToken(t, db, "lukas")
	rec := uploadFile(t, handler, lukas, "file", "mein lied.wav", tinyWAV())
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload -> %d, wanted 201 (%s)", rec.Code, rec.Body)
	}

	var track Track
	if err := json.Unmarshal(rec.Body.Bytes(), &track); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if track.ID == 0 || track.Title != "mein lied.wav" || track.Uploader != "lukas" {
		t.Errorf("answer is incomplete: %s", rec.Body)
	}
	if track.Size != int64(len(tinyWAV())) || track.ContentType != "audio/wav" {
		t.Errorf("wrong size or content type: %s", rec.Body)
	}

	// The file is in the shared library folder under the generated name.
	saved, err := os.ReadFile(filepath.Join(library, track.StoredName))
	if err != nil {
		t.Fatalf("the song is not in the library folder: %v", err)
	}
	if !bytes.Equal(saved, tinyWAV()) {
		t.Errorf("the saved file does not match what was uploaded")
	}

	// The library is shared: another user reads the same track and the same file.
	nina := testToken(t, db, "nina")
	var seen Track
	err = db.QueryRow(`SELECT id, user_id, title, stored_name, size, content_type, uploaded_at FROM track WHERE id = ?`, track.ID).
		Scan(&seen.ID, &seen.UserID, &seen.Title, &seen.StoredName, &seen.Size, &seen.ContentType, &seen.UploadedAt)
	if err != nil {
		t.Fatalf("another user cannot read the track: %v", err)
	}
	if seen.StoredName != track.StoredName {
		t.Errorf("the row does not point at the file in the library")
	}
	if seen.UserID == 0 {
		t.Errorf("the track does not record who uploaded it")
	}

	// The same title from someone else is a second file, never an overwrite.
	rec = uploadFile(t, handler, nina, "file", "mein lied.wav", tinyWAV())
	if rec.Code != http.StatusCreated {
		t.Fatalf("second upload -> %d (%s)", rec.Code, rec.Body)
	}
	var other Track
	if err := json.Unmarshal(rec.Body.Bytes(), &other); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if other.StoredName == track.StoredName {
		t.Errorf("the second upload overwrote the first file")
	}
	if other.Uploader != "nina" {
		t.Errorf("the second upload is not attributed to its uploader: %s", rec.Body)
	}
}

// TestUploadRejectsBadUploads covers the input rules: only real audio, never
// empty, never over the size limit, always in the "file" field.
func TestUploadRejectsBadUploads(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	handler := uploadHandler(db, library, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	cases := []struct {
		name    string
		field   string
		file    string
		content []byte
		status  int
	}{
		{"plain text named like audio", "file", "notes.txt", []byte("just text"), http.StatusBadRequest},
		{"plain text renamed .mp3", "file", "notes.mp3", []byte("just text"), http.StatusBadRequest},
		{"an image named like audio", "file", "cover.mp3", []byte("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"), http.StatusBadRequest},
		{"extension not allowed", "file", "song.zip", notAudio, http.StatusBadRequest},
		{"empty file", "file", "empty.wav", []byte{}, http.StatusBadRequest},
		{"field is not a file", "file", "", notAudio, http.StatusBadRequest},
		{"wrong field name", "upload", "song.flac", notAudio, http.StatusBadRequest},
		{"no file at all", "", "", nil, http.StatusBadRequest},
		{"larger than 500 MiB", "file", "big.wav", bytes.Repeat([]byte{0}, maxUploadBytes+1), http.StatusRequestEntityTooLarge},
	}

	for _, c := range cases {
		rec := uploadFile(t, handler, token, c.field, c.file, c.content)
		if rec.Code != c.status {
			t.Errorf("%s -> %d, wanted %d (%s)", c.name, rec.Code, c.status, rec.Body)
		}
	}

	// A request that is not multipart at all is refused before anything is read.
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/music/upload", strings.NewReader("not multipart"))
	req.Header.Set("Authorization", "Bearer "+token)
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("not multipart -> %d, wanted 400 (%s)", rec.Code, rec.Body)
	}

	// A client name that tries to climb out of the folder is stored inside it.
	rec = uploadFile(t, handler, token, "file", "../escape.flac", notAudio)
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload with ../ in the name -> %d (%s)", rec.Code, rec.Body)
	}
	var track Track
	if err := json.Unmarshal(rec.Body.Bytes(), &track); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if strings.ContainsRune(track.StoredName, '/') {
		t.Errorf("stored name is not a plain library file name: %s", track.StoredName)
	}
	if track.Title != "escape.flac" {
		t.Errorf("title was not reduced to the base name: %s", track.Title)
	}
	if track.ContentType != "audio/flac" {
		t.Errorf("an unsniffable audio container is stored with its extension type, got %s", track.ContentType)
	}
	if _, err := os.Stat(filepath.Join(library, track.StoredName)); err != nil {
		t.Errorf("the file is not inside the library folder: %v", err)
	}
}

func TestUploadRateLimit(t *testing.T) {
	db := openTestDB(t)
	handler := uploadHandler(db, t.TempDir(), newRateLimiter(2, time.Second))
	token := testToken(t, db, "lukas")

	for i := 0; i < 2; i++ {
		rec := uploadFile(t, handler, token, "file", "song.wav", tinyWAV())
		if rec.Code != http.StatusCreated {
			t.Fatalf("upload %d -> %d, wanted 201 (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := uploadFile(t, handler, token, "file", "song.wav", tinyWAV())
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third upload -> %d, wanted 429 (%s)", rec.Code, rec.Body)
	}
	checkRetryAfter(t, rec, 1)

	// The upload bucket is its own: a full bucket answers before the token is
	// looked up, so a flood of anonymous uploads cannot starve the session checks.
	rec = uploadFile(t, handler, "", "file", "song.wav", tinyWAV())
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("upload bucket must be separate -> %d (%s)", rec.Code, rec.Body)
	}
}

// get sends one GET with a Bearer token, through a mux so that r.PathValue has the
// value main.go would give it.
func get(t *testing.T, handler http.Handler, path, token string) *httptest.ResponseRecorder {
	t.Helper()

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	handler.ServeHTTP(rec, req)
	return rec
}

func musicMux(db *sql.DB, library string, limiter *rateLimiter) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/music", listHandler(db, limiter))
	mux.HandleFunc("GET /api/music/{id}", streamHandler(db, library, limiter))
	return mux
}

// chunkRecorder records how many body bytes were present at each flush. It is the
// only way a test can tell piece-by-piece delivery from one whole-file write.
type chunkRecorder struct {
	*httptest.ResponseRecorder
	chunks []int
}

func (c *chunkRecorder) Flush() {
	c.chunks = append(c.chunks, c.Body.Len())
	c.ResponseRecorder.Flush()
}

// bigWAV is a real WAV header with enough padding to span several stream chunks.
func bigWAV() []byte {
	return append(tinyWAV(), bytes.Repeat([]byte{0}, 3*streamChunkBytes)...)
}

// TestListRequiresAuth: reading the shared library needs an account, with the same two
// 401 messages as GET /api/session.
func TestListRequiresAuth(t *testing.T) {
	db := openTestDB(t)
	handler := musicMux(db, t.TempDir(), newRateLimiter(100, time.Second))

	rec := get(t, handler, "/api/music", "")
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "authorization header") {
		t.Errorf("anonymous list -> %d (%s), wanted 401 with the missing-header message", rec.Code, rec.Body)
	}

	rec = get(t, handler, "/api/music", "not-a-known-token")
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Body.String(), "session is not valid or expired") {
		t.Errorf("unknown token -> %d (%s), wanted 401 with the session message", rec.Code, rec.Body)
	}
}

func TestListTracks(t *testing.T) {
	db := openTestDB(t)
	handler := musicMux(db, t.TempDir(), newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	// An empty library answers [], not null.
	rec := get(t, handler, "/api/music", token)
	if rec.Code != http.StatusOK {
		t.Fatalf("list -> %d (%s)", rec.Code, rec.Body)
	}
	if strings.TrimSpace(rec.Body.String()) != "[]" {
		t.Errorf("empty library answered %s, wanted []", rec.Body)
	}

	// Rows are inserted out of insertion order. This cannot prove the sort: for
	// INTEGER PRIMARY KEY the id is the rowid, so a plain scan already returns rows in
	// id order. It is tested because ORDER BY id is what the answer promises, and the
	// promise must hold if the schema ever changes.
	user, err := GetUserByUsername(db, "lukas")
	if err != nil {
		t.Fatalf("load the user: %v", err)
	}
	now := time.Now().Unix()
	for _, id := range []int64{5, 2} {
		if _, err := db.Exec(`INSERT INTO track (id, user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
			id, user.ID, "song-"+strconv.FormatInt(id, 10)+".wav", "file-"+strconv.FormatInt(id, 10)+".wav", 1, "audio/wav", now); err != nil {
			t.Fatalf("insert row %d: %v", id, err)
		}
	}

	rec = get(t, handler, "/api/music", token)
	if rec.Code != http.StatusOK {
		t.Fatalf("list -> %d (%s)", rec.Code, rec.Body)
	}

	var entries []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("list has %d entries, wanted 2 (%s)", len(entries), rec.Body)
	}
	if entries[0]["id"] != float64(2) || entries[1]["id"] != float64(5) {
		t.Errorf("the list is not ordered by id: %s", rec.Body)
	}
	if entries[0]["title"] != "song-2.wav" || entries[1]["title"] != "song-5.wav" {
		t.Errorf("the titles do not match the ids: %s", rec.Body)
	}

	// id and title only: the name the file has inside the library folder stays on the
	// server.
	for _, e := range entries {
		if len(e) != 2 {
			t.Errorf("an entry carries more than id and title: %v", e)
		}
	}
}

// TestStreamSendsChunks is the point of this endpoint: the file goes out piece by
// piece, so a player gets the beginning of a song before the rest is read.
func TestStreamSendsChunks(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	upload := uploadHandler(db, library, newRateLimiter(100, time.Second))
	handler := musicMux(db, library, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	rec := uploadFile(t, upload, token, "file", "song.wav", bigWAV())
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload -> %d (%s)", rec.Code, rec.Body)
	}
	var track Track
	if err := json.Unmarshal(rec.Body.Bytes(), &track); err != nil {
		t.Fatalf("decode answer: %v", err)
	}

	stream := &chunkRecorder{ResponseRecorder: httptest.NewRecorder()}
	req := httptest.NewRequest(http.MethodGet, "/api/music/"+strconv.FormatInt(track.ID, 10), nil)
	req.Header.Set("Authorization", "Bearer "+token)
	handler.ServeHTTP(stream, req)

	if stream.Code != http.StatusOK {
		t.Fatalf("stream -> %d (%s)", stream.Code, stream.Body)
	}
	if stream.Header().Get("Content-Type") != "audio/wav" {
		t.Errorf("the stored content type must be the response content type: %q", stream.Header().Get("Content-Type"))
	}
	if stream.Header().Get("Content-Length") != strconv.Itoa(len(bigWAV())) {
		t.Errorf("Content-Length %q, wanted %d", stream.Header().Get("Content-Length"), len(bigWAV()))
	}
	if stream.Header().Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("the stream answer must carry nosniff like every other answer: %v", stream.Header())
	}
	if stream.Body.Len() != len(bigWAV()) {
		t.Errorf("streamed %d bytes, wanted %d", stream.Body.Len(), len(bigWAV()))
	}

	// The body must arrive as several chunks, each no larger than the chunk size, and
	// the first flush must be smaller than the whole file.
	if len(stream.chunks) < 2 {
		t.Fatalf("the body was sent in %d piece(s), not in chunks", len(stream.chunks))
	}
	previous := 0
	for i, size := range stream.chunks {
		if size <= previous {
			t.Errorf("flush %d did not add bytes: %v", i+1, stream.chunks)
		}
		if size-previous > streamChunkBytes {
			t.Errorf("flush %d sent %d bytes, more than the %d byte chunk size", i+1, size-previous, streamChunkBytes)
		}
		previous = size
	}
	if stream.chunks[0] >= len(bigWAV()) {
		t.Errorf("the whole file was flushed at once, so nothing was streamed")
	}

	// A file smaller than one chunk is still one flush, not zero.
	small := uploadFile(t, upload, token, "file", "small.wav", tinyWAV())
	if small.Code != http.StatusCreated {
		t.Fatalf("small upload -> %d (%s)", small.Code, small.Body)
	}
	var smallTrack Track
	if err := json.Unmarshal(small.Body.Bytes(), &smallTrack); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	smallStream := &chunkRecorder{ResponseRecorder: httptest.NewRecorder()}
	req = httptest.NewRequest(http.MethodGet, "/api/music/"+strconv.FormatInt(smallTrack.ID, 10), nil)
	req.Header.Set("Authorization", "Bearer "+token)
	handler.ServeHTTP(smallStream, req)
	if len(smallStream.chunks) != 1 {
		t.Errorf("a small file was flushed %d times, wanted once", len(smallStream.chunks))
	}
}

// TestStreamRejectsBadRequests covers the answers before the first byte, which are the
// only ones that can still use the JSON error shape.
func TestStreamRejectsBadRequests(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	upload := uploadHandler(db, library, newRateLimiter(100, time.Second))
	handler := musicMux(db, library, newRateLimiter(100, time.Second))
	token := testToken(t, db, "lukas")

	rec := uploadFile(t, upload, token, "file", "song.wav", tinyWAV())
	if rec.Code != http.StatusCreated {
		t.Fatalf("upload -> %d (%s)", rec.Code, rec.Body)
	}
	var track Track
	if err := json.Unmarshal(rec.Body.Bytes(), &track); err != nil {
		t.Fatalf("decode answer: %v", err)
	}

	cases := []struct {
		name   string
		path   string
		token  string
		status int
		want   string
	}{
		{"no header", "/api/music/1", "", http.StatusUnauthorized, "authorization header"},
		{"unknown token", "/api/music/1", "not-a-known-token", http.StatusUnauthorized, "session is not valid or expired"},
		{"id is not a number", "/api/music/abc", token, http.StatusBadRequest, "the song id must be a positive number"},
		{"id is negative", "/api/music/-1", token, http.StatusBadRequest, "the song id must be a positive number"},
		{"id is zero", "/api/music/0", token, http.StatusBadRequest, "the song id must be a positive number"},
		{"id has leading zeros", "/api/music/0004", token, http.StatusBadRequest, "the song id must be a positive number"},
		{"id has a plus sign", "/api/music/+4", token, http.StatusBadRequest, "the song id must be a positive number"},
		{"id is digits but too large", "/api/music/9223372036854775808", token, http.StatusBadRequest, "the song id is too large"},
		{"id is not in the library", "/api/music/999", token, http.StatusNotFound, "song is not in the library"},
	}

	for _, c := range cases {
		rec := get(t, handler, c.path, c.token)
		if rec.Code != c.status || !strings.Contains(rec.Body.String(), c.want) {
			t.Errorf("%s -> %d (%s), wanted %d with %q", c.name, rec.Code, rec.Body, c.status, c.want)
		}
	}

	// A row whose file is gone is a broken library: the song is listed but cannot be
	// played, and the answer must say which.
	if err := os.Remove(filepath.Join(library, track.StoredName)); err != nil {
		t.Fatalf("remove the file: %v", err)
	}
	rec = get(t, handler, "/api/music/"+strconv.FormatInt(track.ID, 10), token)
	if rec.Code != http.StatusNotFound || !strings.Contains(rec.Body.String(), "is not in the library folder") {
		t.Errorf("row with a missing file -> %d (%s), wanted 404 naming the missing file", rec.Code, rec.Body)
	}
}

// TestStreamRateLimit checks that the two read buckets are separate. It uses two
// limiter instances the way main.go wires them; that is also what it can prove — a
// shared instance would fail here.
func TestStreamRateLimit(t *testing.T) {
	db := openTestDB(t)
	library := t.TempDir()
	token := testToken(t, db, "lukas")

	// A full stream bucket must not stop the list.
	streamFull := musicMux(db, library, newRateLimiter(2, time.Second))
	listOpen := musicMux(db, library, newRateLimiter(2, time.Second))

	for i := 0; i < 2; i++ {
		rec := get(t, streamFull, "/api/music/1", token)
		if rec.Code != http.StatusNotFound {
			t.Fatalf("stream %d -> %d, wanted the 404 for an empty library (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := get(t, streamFull, "/api/music/1", token)
	if rec.Code != http.StatusTooManyRequests || !strings.Contains(rec.Body.String(), "too many requests from this address") {
		t.Fatalf("third stream -> %d (%s), wanted 429", rec.Code, rec.Body)
	}
	checkRetryAfter(t, rec, 1)

	rec = get(t, listOpen, "/api/music", token)
	if rec.Code != http.StatusOK {
		t.Errorf("a full stream bucket stopped the list -> %d (%s)", rec.Code, rec.Body)
	}

	// The other way round: a full list bucket must not stop playback.
	listFull := musicMux(db, library, newRateLimiter(2, time.Second))
	streamOpen := musicMux(db, library, newRateLimiter(2, time.Second))

	for i := 0; i < 3; i++ {
		rec = get(t, listFull, "/api/music", token)
	}
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third list -> %d, wanted 429 (%s)", rec.Code, rec.Body)
	}

	rec = get(t, streamOpen, "/api/music/1", token)
	if rec.Code != http.StatusNotFound {
		t.Errorf("a full list bucket stopped playback -> %d (%s)", rec.Code, rec.Body)
	}
}
