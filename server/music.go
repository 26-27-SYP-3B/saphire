package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
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
//
// Artist and DurationMS are what the file itself said (see metadata.go). A file
// that does not say them stays empty or zero, and the client shows a dash.
type Track struct {
	ID          int64  `json:"id"`
	UserID      int64  `json:"-"`
	Uploader    string `json:"uploaded_by"`
	Title       string `json:"title"`
	Artist      string `json:"artist"`
	DurationMS  int64  `json:"duration_ms"`
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

// positiveIDPattern is an id as the database writes it: digits only, no sign, no
// leading zeros. "0" and "-1" are not ids, and "0004" would be the same song or the
// same slot under two names. It is used for song ids and for positions.
var positiveIDPattern = regexp.MustCompile(`^[1-9][0-9]*$`)

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
			artist TEXT NOT NULL DEFAULT '',
			duration_ms INTEGER NOT NULL DEFAULT 0,
			stored_name TEXT NOT NULL UNIQUE,
			size INTEGER NOT NULL,
			content_type TEXT NOT NULL,
			uploaded_at INTEGER NOT NULL
		)`)
	if err != nil {
		return err
	}
	return ensureTrackColumns(db)
}

// ensureTrackColumns adds the metadata columns to a table that was created before
// they existed: CREATE TABLE IF NOT EXISTS never changes a table that is already
// there, so an existing saphire.db needs each missing column on its own. Existing
// rows get the default, which is what an untagged file has anyway.
//
// The names here are fixed literals, not user input, so building the statement is
// safe even though every other query in this server is parameterized.
func ensureTrackColumns(db *sql.DB) error {
	rows, err := db.Query(`PRAGMA table_info(track)`)
	if err != nil {
		return err
	}
	defer rows.Close()

	have := map[string]bool{}
	for rows.Next() {
		var (
			no      int
			name    string
			decl    string
			notNull int
			dflt    any
			pk      int
		)
		if err := rows.Scan(&no, &name, &decl, &notNull, &dflt, &pk); err != nil {
			return err
		}
		have[name] = true
	}
	if err := rows.Err(); err != nil {
		return err
	}

	// ALTER TABLE has no "IF NOT EXISTS", so only the columns that are missing are added.
	for _, column := range []string{"artist TEXT NOT NULL DEFAULT ''", "duration_ms INTEGER NOT NULL DEFAULT 0"} {
		if have[strings.Fields(column)[0]] {
			continue
		}
		if _, err := db.Exec("ALTER TABLE track ADD COLUMN " + column); err != nil {
			return err
		}
	}
	return nil
}

// rowScanner is what both sql.Row and sql.Rows are, so one scan function serves a
// single lookup and a list.
type rowScanner interface {
	Scan(dest ...any) error
}

// trackColumns are the columns a track is read with. The uploader is joined from
// the user table, because the library answer shows a name, not a bare id.
const trackColumns = `track.id, track.user_id, track.title, track.artist, track.duration_ms,
	track.stored_name, track.size, track.content_type, track.uploaded_at, user.username`

// scanTrack reads one row into a Track. The column order is the one above.
func scanTrack(row rowScanner) (Track, error) {
	var t Track
	err := row.Scan(&t.ID, &t.UserID, &t.Title, &t.Artist, &t.DurationMS,
		&t.StoredName, &t.Size, &t.ContentType, &t.UploadedAt, &t.Uploader)
	return t, err
}

// GetTrackByID loads one library row. Returns sql.ErrNoRows when it does not exist.
// It reads the same columns and the same scan function as the list, so a single lookup
// and a list cannot disagree about what a row contains.
func GetTrackByID(db *sql.DB, id int64) (*Track, error) {
	row := db.QueryRow(`SELECT `+trackColumns+` FROM track JOIN user ON user.id = track.user_id WHERE track.id = ?`, id)
	track, err := scanTrack(row)
	if err != nil {
		return nil, err
	}
	return &track, nil
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
	res, err := db.Exec(`INSERT INTO track (user_id, title, artist, duration_ms, stored_name, size, content_type, uploaded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		t.UserID, t.Title, t.Artist, t.DurationMS, t.StoredName, t.Size, t.ContentType, t.UploadedAt)
	if err != nil {
		return err
	}
	t.ID, err = res.LastInsertId()
	if err != nil {
		return err
	}
	return nil
}

// ListTracks returns the whole library ordered by id, as one full row per song. The
// library is shared, so the list shows who added a song and what the file said about
// itself; a row without tags reads as an empty artist and a length of 0, which the
// client shows as a dash rather than a guess.
func ListTracks(db *sql.DB) ([]Track, error) {
	rows, err := db.Query(`SELECT ` + trackColumns + ` FROM track JOIN user ON user.id = track.user_id ORDER BY track.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// An empty library answers [] rather than null, so a client does not have to tell
	// the two apart.
	tracks := []Track{}
	for rows.Next() {
		track, err := scanTrack(rows)
		if err != nil {
			return nil, err
		}
		tracks = append(tracks, track)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return tracks, nil
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

// withoutControlChars copies value without control characters, at most maxLen
// characters. A name is shown to a person, so this counts characters, not bytes —
// counting bytes would cut a multi-byte letter in half. Both a title and a playlist
// name are cleaned this way, so they agree on what is acceptable. This is also what
// a tag read out of a file goes through (see metadata.go), so a tag cannot be longer
// than a name.
func withoutControlChars(value string, maxLen int) string {
	var b strings.Builder
	count := 0
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			continue
		}
		if count >= maxLen {
			break
		}
		b.WriteRune(r)
		count++
	}
	return strings.TrimSpace(b.String())
}

// sanitizeTitle makes the name the client sent safe to show in the shared library:
// base name only, then the same cleaning as any text a person is shown.
func sanitizeTitle(name string) string {
	return withoutControlChars(path.Base(strings.ReplaceAll(name, "\x00", "")), maxTitleLen)
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

		// The artist and the playing time come from the file itself. They are read
		// before anything is stored, so the row and the answer show the same values.
		// Only MP3 has a length that can be worked out from the bytes; the other
		// containers keep 0, which the client shows as a dash.
		meta := audioMeta{}
		if contentType == "audio/mpeg" {
			meta = readAudioMeta(data)
		}

		// The title is what the file names itself when its tags do, otherwise the
		// name the client sent.
		title := meta.Title
		if title == "" {
			title = sanitizeTitle(part.FileName())
		}
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
			Artist:      meta.Artist,
			DurationMS:  meta.DurationMS,
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
		if !positiveIDPattern.MatchString(idText) {
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

		// Everything that can still be answered with the JSON error shape must be
		// decided here: after WriteHeader the status is fixed, and a later failure can
		// only end the body.
		w.Header().Set("Content-Type", track.ContentType)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Accept-Ranges", "bytes")
		// The stored name is what the file is called inside the library folder, and it
		// is what the upload answer reported, so a player that saved the row can name
		// the file it is fetching.
		w.Header().Set("Content-Disposition", `inline; filename="`+filepath.Base(track.StoredName)+`"`)

		// A player asks for a range so a song can start before the whole file is read.
		// One range is supported, not a list, because that is what an audio player sends.
		from, to := int64(0), info.Size()-1
		if header := r.Header.Get("Range"); header != "" {
			start, end, ok := parseByteRange(header, info.Size())
			if !ok {
				// A range that cannot be read as bytes, or one outside the file, is
				// answered as plain text: the caller here is a player, and this error is
				// about the transport, not about the API.
				w.Header().Set("Content-Range", "bytes */"+strconv.FormatInt(info.Size(), 10))
				writePlainText(w, http.StatusRequestedRangeNotSatisfiable, "invalid range")
				return
			}
			from, to = start, end
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", from, to, info.Size()))
		}

		if from > 0 {
			if _, err := file.Seek(from, io.SeekStart); err != nil {
				writeError(w, http.StatusInternalServerError, "could not read the file")
				return
			}
		}

		// Content-Length is the part that is actually sent, so a player can show
		// progress. It does not change how the body is written: the chunks still go out
		// one by one.
		w.Header().Set("Content-Length", strconv.FormatInt(to-from+1, 10))
		if from > 0 || r.Header.Get("Range") != "" {
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.WriteHeader(http.StatusOK)
		}

		buffer := make([]byte, streamChunkBytes)
		flusher, canFlush := w.(http.Flusher)
		remaining := to - from + 1

		for remaining > 0 {
			want := min(remaining, int64(len(buffer)))
			n, err := file.Read(buffer[:want])
			if n > 0 {
				if _, err := w.Write(buffer[:n]); err != nil {
					return // the client went away mid-stream
				}
				if canFlush {
					flusher.Flush()
				}
				remaining -= int64(n)
			}
			if err != nil {
				// EOF is the normal end. A read error after the status line cannot be
				// reported as JSON, so the body simply stops here.
				return
			}
		}
	}
}

// parseByteRange reads one "bytes=<from>-<to>" range for a file of the given size and
// says whether it can be served. A range that names nothing inside the file is not
// satisfiable, and a range with two parts ("bytes=0-10,20-30") is not read here: an
// audio player sends one range. An open end ("bytes=900-") means the rest of the file,
// and a leading dash ("bytes=-500") means the last 500 bytes.
func parseByteRange(header string, size int64) (int64, int64, bool) {
	value := strings.TrimPrefix(header, "bytes=")
	if value == header || strings.Contains(value, ",") || size == 0 {
		return 0, 0, false
	}

	fromText, toText, hasEnd := strings.Cut(value, "-")
	if hasEnd && strings.Contains(toText, "-") {
		return 0, 0, false // two dashes is not a range this server reads
	}

	var from, to int64
	switch {
	case fromText == "" && hasEnd: // bytes=-<n>: the last n bytes
		n, err := strconv.ParseInt(toText, 10, 64)
		if err != nil || n <= 0 || n > size {
			return 0, 0, false
		}
		from, to = size-n, size-1
	case hasEnd && toText == "": // bytes=<from>-: from the start of the range to the end of the file
		start, err := strconv.ParseInt(fromText, 10, 64)
		if err != nil || start >= size {
			return 0, 0, false
		}
		from, to = start, size-1
	case hasEnd:
		start, err := strconv.ParseInt(fromText, 10, 64)
		end, err2 := strconv.ParseInt(toText, 10, 64)
		if err != nil || err2 != nil {
			return 0, 0, false
		}
		if start >= size || end >= size || start > end {
			return 0, 0, false
		}
		from, to = start, end
	default: // no dash is not a byte range an audio player can send
		return 0, 0, false
	}

	return from, to, true
}
