package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
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
	maxUploadBytes = 20 << 20 // 20 MiB
	maxTitleLen    = 200
)

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
		// the server read 20 MiB it will throw away.
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
				writeError(w, http.StatusRequestEntityTooLarge, "upload is larger than 20 MiB")
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
				writeError(w, http.StatusRequestEntityTooLarge, "upload is larger than 20 MiB")
				return
			}
			writeError(w, http.StatusBadRequest, "the upload could not be read")
			return
		}
		if len(data) > maxUploadBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "upload is larger than 20 MiB")
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
