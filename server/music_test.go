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
		{"larger than 20 MiB", "file", "big.wav", bytes.Repeat([]byte{0}, maxUploadBytes+1), http.StatusRequestEntityTooLarge},
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
