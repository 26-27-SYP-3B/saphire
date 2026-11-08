package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Track is a row of the "track" table: one song in the shared library.
// The library folder belongs to the server, not to a user, so a track stores
// who uploaded it and under which name the file lives. Uploader is not a
// column; it is filled for the response so the shared library shows the name
// instead of a bare user id.
type Track struct {
	ID          int64  `json:"id"`
	UserID      int64  `json:"-"`
	Uploader    string `json:"uploaded_by"`
	Title       string `json:"title"`
	StoredName  string `json:"stored_name"`
	Size        int64  `json:"size"`
	ContentType string `json:"content_type"`
	UploadedAt  int64  `json:"uploaded_at"`
}

// Upload limits. The body limit covers the multipart framing plus the file; a
// single song must not be able to fill the disk.
const (
	maxUploadBytes = 500 << 20 // 500 MiB
	maxTitleLen    = 200

	// streamChunkBytes is how much of a file goes out at a time. Small enough that a
	// player starts playing before the whole file is read, large enough that a
	// 500 MiB song is not sent in tiny pieces.
	streamChunkBytes = 32 << 10 // 32 KiB
)

// songIDPattern is the id as the database writes it: digits only, no sign, no leading
// zeros. "0" and "-1" are not ids, and "0004" would be the same song under two names.
var songIDPattern = regexp.MustCompile(`^[1-9][0-9]*$`)

// audioExtensions are the formats the library accepts, with the content type
// they are reported as. http.DetectContentType cannot sniff every audio
// container (M4A, Ogg and FLAC read as application/octet-stream), so the
// extension decides those cases; for the formats it can sniff, the bytes must
// actually be audio.
var audioExtensions = map[string]string{
	".mp3":  "audio/mpeg",
	".wav":  "audio/wav",
	".m4a":  "audio/mp4",
	".ogg":  "audio/ogg",
	".opus": "audio/ogg",
	".flac": "audio/flac",
	".aac":  "audio/aac",
}

// normalizeAudioType maps the legacy names http.DetectContentType reports to the
// media types stored here, so one format always has one name. Go calls WAV
// "audio/wave"; RFC 2361 lists both, and clients expect "audio/wav".
func normalizeAudioType(mediaType string) string {
	if mediaType == "audio/wave" {
		return "audio/wav"
	}
	return mediaType
}

// detectAudioType decides what an uploaded file is. The extension must be an
// allowed audio format, and the bytes must agree with it when they can be
// sniffed. http.DetectContentType cannot name M4A, Ogg or FLAC (they read as
// application/octet-stream), so those are accepted on the extension alone; a
// text file or an image renamed .mp3 is refused.
func detectAudioType(ext string, data []byte) (string, error) {
	byExtension, ok := audioExtensions[ext]
	if !ok {
		return "", errors.New("only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)")
	}

	sniffed := normalizeAudioType(http.DetectContentType(data))
	if sniffed == "application/octet-stream" {
		return byExtension, nil
	}
	if !strings.HasPrefix(sniffed, "audio/") {
		return "", errors.New("the uploaded file is not audio, its content reads as " + sniffed)
	}
	return sniffed, nil
}

// ensureTrackTable creates the library table. Called from OpenDB so tests get
// the same schema as the server.
func ensureTrackTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS track (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user_id INTEGER NOT NULL REFERENCES user(id),
			title TEXT NOT NULL,
			stored_name TEXT NOT NULL UNIQUE,
			size INTEGER NOT NULL,
			content_type TEXT NOT NULL,
			uploaded_at INTEGER NOT NULL
		)`)
	return err
}

// OpenLibrary creates the shared music library folder (SAPHIRE_LIBRARY_PATH,
// default "library") and returns its path. Every uploaded song is saved there,
// so the library is the same for all users.
func OpenLibrary() (string, error) {
	dir := os.Getenv("SAPHIRE_LIBRARY_PATH")
	if dir == "" {
		dir = "library"
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	return dir, nil
}

// Insert saves the track and fills in its ID.
func (t *Track) Insert(db *sql.DB) error {
	res, err := db.Exec(`INSERT INTO track (user_id, title, stored_name, size, content_type, uploaded_at) VALUES (?, ?, ?, ?, ?, ?)`,
		t.UserID, t.Title, t.StoredName, t.Size, t.ContentType, t.UploadedAt)
	if err != nil {
		return err
	}
	t.ID, err = res.LastInsertId()
	if err != nil {
		return err
	}
	return nil
}

// GetTrackByID loads one library row. Returns sql.ErrNoRows when it does not exist.
func GetTrackByID(db *sql.DB, id int64) (*Track, error) {
	var t Track
	err := db.QueryRow(`SELECT id, user_id, title, stored_name, size, content_type, uploaded_at FROM track WHERE id = ?`, id).
		Scan(&t.ID, &t.UserID, &t.Title, &t.StoredName, &t.Size, &t.ContentType, &t.UploadedAt)
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// LibraryEntry is what GET /api/music shows for one song: the two fields a client
// needs to list the library, and nothing else. The name the file has inside the
// library folder stays on the server.
type LibraryEntry struct {
	ID    int64  `json:"id"`
	Title string `json:"title"`
}

// ListTracks returns the whole library ordered by id. Always parameterized.
func ListTracks(db *sql.DB) ([]LibraryEntry, error) {
	rows, err := db.Query(`SELECT id, title FROM track ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// An empty library answers [] rather than null, so a client does not have to tell
	// the two apart.
	entries := []LibraryEntry{}
	for rows.Next() {
		var e LibraryEntry
		if err := rows.Scan(&e.ID, &e.Title); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}

// storedFileName turns an uploaded name into a name inside the library. The name
// is generated here from random bytes, so a client name like "../evil.mp3"
// cannot escape the library folder or overwrite another user's file — the shared
// library has no per-user path.
func storedFileName(ext string) (string, error) {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf) + ext, nil
}

// sanitizeTitle makes the name the client sent safe to show in the shared
// library: base name only, no control characters, at most maxTitleLen characters.
func sanitizeTitle(name string) string {
	name = path.Base(strings.ReplaceAll(name, "\x00", ""))

	var b strings.Builder
	count := 0
	for _, r := range name {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if count >= maxTitleLen {
			break
		}
		b.WriteRune(r)
		count++
	}
	return strings.TrimSpace(b.String())
}

// uploadHandler answers POST /api/music/upload for a logged-in user.
// Anonymous callers are refused: uploading is the only way a song enters the
// shared library, so it needs an account. The request is multipart/form-data
// with one file in a field named "file".
func uploadHandler(db *sql.DB, library string, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if ok, retry := limiter.allow(ip); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(retry))
			writeError(w, http.StatusTooManyRequests, "too many uploads from this address, try again later")
			return
		}

		// Auth before reading the body, so an unauthenticated caller cannot make
		// the server read 500 MiB it will throw away.
		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		if !strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
			writeError(w, http.StatusBadRequest, "body must be a multipart/form-data request with a \"file\" field")
			return
		}

		var maxBytesErr *http.MaxBytesError
		r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)

		mr, err := r.MultipartReader()
		if err != nil {
			writeError(w, http.StatusBadRequest, "body must be a multipart/form-data request with a \"file\" field")
			return
		}

		part, err := mr.NextPart()
		if err != nil {
			if errors.As(err, &maxBytesErr) {
				writeError(w, http.StatusRequestEntityTooLarge, "upload is larger than 500 MiB")
				return
			}
			if errors.Is(err, io.EOF) {
				writeError(w, http.StatusBadRequest, "no file was uploaded")
				return
			}
			writeError(w, http.StatusBadRequest, "the upload could not be read")
			return
		}
		defer part.Close()

		if part.FormName() != "file" || part.FileName() == "" {
			writeError(w, http.StatusBadRequest, "the file must be sent in a form field named \"file\"")
			return
		}

		data, err := io.ReadAll(io.LimitReader(part, maxUploadBytes+1))
		if err != nil {
			if errors.As(err, &maxBytesErr) {
				writeError(w, http.StatusRequestEntityTooLarge, "upload is larger than 500 MiB")
				return
			}
			writeError(w, http.StatusBadRequest, "the upload could not be read")
			return
		}
		if len(data) > maxUploadBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "upload is larger than 500 MiB")
			return
		}
		if len(data) == 0 {
			writeError(w, http.StatusBadRequest, "the uploaded file is empty")
			return
		}

		ext := strings.ToLower(path.Ext(part.FileName()))
		contentType, err := detectAudioType(ext, data)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		title := sanitizeTitle(part.FileName())
		if title == "" {
			writeError(w, http.StatusBadRequest, "the uploaded file has no usable name")
			return
		}

		stored, err := storedFileName(ext)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not name the file")
			return
		}

		// The file first, then the row: writing the row first could leave a
		// library entry pointing at a file that is not there. If the insert
		// fails, the file is removed so nothing is left half-saved.
		target := filepath.Join(library, stored)
		if err := os.WriteFile(target, data, 0o644); err != nil {
			writeError(w, http.StatusInternalServerError, "could not save the file")
			return
		}

		track := &Track{
			UserID:      user.ID,
			Title:       title,
			StoredName:  stored,
			Size:        int64(len(data)),
			ContentType: contentType,
			UploadedAt:  time.Now().Unix(),
		}
		if err := track.Insert(db); err != nil {
			_ = os.Remove(target)
			writeError(w, http.StatusInternalServerError, "could not save the upload")
			return
		}
		track.Uploader = user.Username

		writeJSON(w, http.StatusCreated, track)
	}
}

// listHandler answers GET /api/music for a logged-in user: every song in the shared
// library as id and title, ordered by id. The library is shared, so the list is the
// same for everyone who is logged in.
func listHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if ok, retry := limiter.allow(clientIP(r)); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(retry))
			writeError(w, http.StatusTooManyRequests, "too many requests from this address, try again later")
			return
		}

		// Reading the library needs an account, with the same two 401 messages as
		// GET /api/session.
		if _, status, message := authenticate(db, r); status != http.StatusOK {
			writeError(w, status, message)
			return
		}

		entries, err := ListTracks(db)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not list the library")
			return
		}

		writeJSON(w, http.StatusOK, entries)
	}
}

// streamHandler answers GET /api/music/{id} for a logged-in user: the file for one
// song, written out in chunks of streamChunkBytes with a flush after each chunk. The
// file is never read into memory as a whole, so a 500 MiB song does not become a
// 500 MiB allocation, and a player gets the first bytes before the rest is read.
func streamHandler(db *sql.DB, library string, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if ok, retry := limiter.allow(ip); !ok {
			w.Header().Set("Retry-After", strconv.Itoa(retry))
			writeError(w, http.StatusTooManyRequests, "too many requests from this address, try again later")
			return
		}

		// Auth before the file is opened, as in the upload endpoint: an anonymous
		// caller must not make the server read a whole song it will not send.
		if _, status, message := authenticate(db, r); status != http.StatusOK {
			writeError(w, status, message)
			return
		}

		// Ids are positive integers as the database produces them, so a form like "-1",
		// "0", "0004" or "+4" is not an id even though it parses as a number.
		idText := r.PathValue("id")
		if !songIDPattern.MatchString(idText) {
			writeError(w, http.StatusBadRequest, "the song id must be a positive number")
			return
		}

		id, err := strconv.ParseInt(idText, 10, 64)
		if err != nil {
			// The characters are digits, so this can only be a value too large to be an
			// id, and the answer must say that instead of "not a number".
			writeError(w, http.StatusBadRequest, "the song id is too large")
			return
		}

		track, err := GetTrackByID(db, id)
		if errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusNotFound, "song is not in the library")
			return
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not load the song")
			return
		}

		// stored_name is generated here, so it cannot name anything outside the
		// library folder.
		file, err := os.Open(filepath.Join(library, track.StoredName))
		if errors.Is(err, fs.ErrNotExist) {
			// The file is written before the row, so this should not happen; it is a
			// broken library, and the client needs to know the song cannot be played.
			writeError(w, http.StatusNotFound, "the file for this song is not in the library folder")
			return
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not read the file")
			return
		}
		defer file.Close()

		// Everything that can still be answered with the JSON error shape must be
		// decided here: after WriteHeader the status is fixed, and a later failure can
		// only end the stream.
		info, err := file.Stat()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not read the file")
			return
		}

		// Content-Length is the size of the file that is actually sent, so a player
		// can show progress. It does not change how the body is written: the chunks
		// still go out one by one.
		w.Header().Set("Content-Type", track.ContentType)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		w.WriteHeader(http.StatusOK)

		buffer := make([]byte, streamChunkBytes)
		flusher, canFlush := w.(http.Flusher)

		for {
			n, err := file.Read(buffer)
			if n > 0 {
				if _, err := w.Write(buffer[:n]); err != nil {
					return // the client went away mid-stream
				}
				if canFlush {
					flusher.Flush()
				}
			}
			if err != nil {
				// EOF is the normal end. A read error after the status line cannot be
				// reported as JSON, so the body simply stops here.
				return
			}
		}
	}
}
