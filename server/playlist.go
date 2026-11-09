package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"
)

// Playlist limits. A name is capped so one answer stays readable, and the number of
// songs is capped so one playlist cannot grow without bound. 200 songs is far more
// than a school project needs; a client that wants more needs pagination (see
// api-docs.md, Upcoming).
const (
	maxPlaylistNameLen = 100
	maxPlaylistSongs   = 200
)

// What a playlist function can report. Each of these is a reason the answer can name,
// so the client is told which one it is instead of a driver error. Their text is the
// wording in api-docs.md, and the number in it comes from the same constant the check
// uses — otherwise raising the cap would make the answer lie.
var (
	ErrPlaylistNotYours    = errors.New("playlist is not in your playlists")
	ErrSongNotInLibrary    = errors.New("song is not in the library")
	ErrPlaylistFull        = errors.New("a playlist holds at most " + strconv.Itoa(maxPlaylistSongs) + " songs")
	ErrPlaylistNameTooLong = errors.New("a playlist name is at most " + strconv.Itoa(maxPlaylistNameLen) + " characters")
)

// positionNotThere names the slot it is about, so the answer says which position was
// empty and in what, instead of a plain "not found". The position is an int64 because it
// comes from a path value that was parsed as one; narrowing it to int would make a 32-bit
// build answer about a different slot than the one that was asked for.
type positionNotThere struct {
	container string
	position  int64
}

func (e *positionNotThere) Error() string {
	return "no song at position " + strconv.FormatInt(e.position, 10) + " in this " + e.container
}

// Playlist is a row of the "playlist" table. A playlist belongs to the user who
// created it, unlike the library, which is shared — so reading one is always
// "my playlists", and a playlist of another user reads as not existing. Two playlists
// may have the same name: nothing in the table says they must differ.
type Playlist struct {
	ID        int64  `json:"id"`
	UserID    int64  `json:"-"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
	SongCount int    `json:"song_count"`
}

// PlaylistSong is one row of "playlist_song": a song at a position. A song can be in
// a playlist more than once, at different positions, because a playlist is an order,
// not a set.
type PlaylistSong struct {
	Position int    `json:"position"`
	TrackID  int64  `json:"track_id"`
	Title    string `json:"title"`
}

// PlaylistWithSongs is what GET /api/playlists/{id} answers. The list endpoint carries
// song_count only, so a client that shows the playlists does not get every song of
// every playlist in one answer.
type PlaylistWithSongs struct {
	Playlist
	Songs []PlaylistSong `json:"songs"`
}

// ensurePlaylistTables creates the playlist tables. Called from OpenDB so tests get the
// same schema as the server.
func ensurePlaylistTables(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS playlist (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			user_id INTEGER NOT NULL REFERENCES user(id),
			name TEXT NOT NULL,
			created_at INTEGER NOT NULL
		)`)
	if err != nil {
		return err
	}

	// position is the order inside the playlist. It is renumbered when a song is
	// removed, so the positions a client sees are always 1..n with no gaps. A song may
	// appear at two positions, so there is no UNIQUE on track_id.
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS playlist_song (
			playlist_id INTEGER NOT NULL REFERENCES playlist(id),
			track_id INTEGER NOT NULL REFERENCES track(id),
			position INTEGER NOT NULL,
			added_at INTEGER NOT NULL
		)`)
	return err
}

// cleanPlaylistName removes control characters, the same rule a title follows, and reports
// whether the name fits the cap. A name that is too long is refused rather than cut: a
// playlist is named by the person who made it, and a silently shorter name would be a
// different playlist than the one they asked for — the same reason the 200 songs cap is a
// refusal and not a drop. Cleaning with one character more than the cap is enough to see
// that the name is longer, and the count is characters, not bytes.
func cleanPlaylistName(name string) (string, bool) {
	cleaned := withoutControlChars(name, maxPlaylistNameLen+1)
	if len([]rune(cleaned)) > maxPlaylistNameLen {
		return "", false
	}
	return cleaned, true
}

// CreatePlaylist saves a playlist and fills in its ID. The name is not unique: the
// same person may have two playlists called "Favoriten", and they are different things.
func CreatePlaylist(db *sql.DB, userID int64, name string) (*Playlist, error) {
	p := &Playlist{
		UserID:    userID,
		Name:      name,
		CreatedAt: time.Now().Unix(),
	}

	res, err := db.Exec(`INSERT INTO playlist (user_id, name, created_at) VALUES (?, ?, ?)`,
		p.UserID, p.Name, p.CreatedAt)
	if err != nil {
		return nil, err
	}

	p.ID, err = res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return p, nil
}

// ListPlaylists returns the caller's own playlists, ordered by id. song_count is a
// count, not the songs: the songs come from GET /api/playlists/{id}.
func ListPlaylists(db *sql.DB, userID int64) ([]Playlist, error) {
	rows, err := db.Query(`
		SELECT p.id, p.name, p.created_at,
			(SELECT COUNT(*) FROM playlist_song WHERE playlist_id = p.id)
		FROM playlist p WHERE p.user_id = ? ORDER BY p.id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// An empty list answers [], not null, so a client does not have to tell the two
	// apart.
	playlists := []Playlist{}
	for rows.Next() {
		var p Playlist
		if err := rows.Scan(&p.ID, &p.Name, &p.CreatedAt, &p.SongCount); err != nil {
			return nil, err
		}
		playlists = append(playlists, p)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return playlists, nil
}

// GetPlaylist loads one playlist with its songs in order. The title comes from the
// library row: a playlist stores references, not copies.
func GetPlaylist(db *sql.DB, userID, id int64) (*PlaylistWithSongs, error) {
	base, err := getPlaylistFor(db, userID, id)
	if err != nil {
		return nil, err
	}

	playlist := &PlaylistWithSongs{Playlist: *base, Songs: []PlaylistSong{}}

	rows, err := db.Query(`
		SELECT s.position, s.track_id, t.title
		FROM playlist_song s JOIN track t ON t.id = s.track_id
		WHERE s.playlist_id = ? ORDER BY s.position`, playlist.ID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	// An empty playlist answers [], not null.
	for rows.Next() {
		var s PlaylistSong
		if err := rows.Scan(&s.Position, &s.TrackID, &s.Title); err != nil {
			return nil, err
		}
		playlist.Songs = append(playlist.Songs, s)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return playlist, nil
}

// getPlaylistFor loads one playlist without its songs. It takes anything that can run
// a parameterized query — the database or an open transaction — so the ownership check
// and the write see the same state.
func getPlaylistFor(q queryRunner, userID, id int64) (*Playlist, error) {
	var p Playlist
	err := q.QueryRow(`SELECT id, name, created_at FROM playlist WHERE id = ? AND user_id = ?`, id, userID).
		Scan(&p.ID, &p.Name, &p.CreatedAt)
	if err != nil {
		return nil, err
	}

	var count int
	if err := q.QueryRow(`SELECT COUNT(*) FROM playlist_song WHERE playlist_id = ?`, p.ID).Scan(&count); err != nil {
		return nil, err
	}
	p.SongCount = count
	return &p, nil
}

// queryRunner is the part of a connection or a transaction that a domain function
// needs: parameterized QueryRow and Query. It is here so a check and the write that
// belongs to it can happen in the same transaction.
type queryRunner interface {
	QueryRow(query string, args ...any) *sql.Row
	Query(query string, args ...any) (*sql.Rows, error)
}

// AddPlaylistSong puts one song at the end of a playlist and returns the position it
// got. Counting and inserting happen in one transaction, so two callers cannot be given
// the same position.
func AddPlaylistSong(db *sql.DB, userID, playlistID, trackID int64) (*PlaylistSong, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	playlist, err := getPlaylistFor(tx, userID, playlistID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrPlaylistNotYours
	}
	if err != nil {
		return nil, err
	}
	if playlist.SongCount >= maxPlaylistSongs {
		return nil, ErrPlaylistFull
	}

	var title string
	err = tx.QueryRow(`SELECT title FROM track WHERE id = ?`, trackID).Scan(&title)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSongNotInLibrary
	}
	if err != nil {
		return nil, err
	}

	position := playlist.SongCount + 1
	if _, err := tx.Exec(`INSERT INTO playlist_song (playlist_id, track_id, position, added_at) VALUES (?, ?, ?, ?)`,
		playlistID, trackID, position, time.Now().Unix()); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &PlaylistSong{Position: position, TrackID: trackID, Title: title}, nil
}

// RemovePlaylistSong takes one position out of a playlist and renumbers the songs after
// it, so the positions a client sees stay 1..n with no gaps.
func RemovePlaylistSong(db *sql.DB, userID, playlistID, position int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := getPlaylistFor(tx, userID, playlistID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrPlaylistNotYours
		}
		return err
	}

	res, err := tx.Exec(`DELETE FROM playlist_song WHERE playlist_id = ? AND position = ?`, playlistID, position)
	if err != nil {
		return err
	}

	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return &positionNotThere{container: "playlist", position: position}
	}

	if _, err := tx.Exec(`UPDATE playlist_song SET position = position - 1 WHERE playlist_id = ? AND position > ?`,
		playlistID, position); err != nil {
		return err
	}

	return tx.Commit()
}

// DeletePlaylist removes a playlist and its songs. The songs themselves stay in the
// shared library: a playlist is a list of references, not a copy of the file.
func DeletePlaylist(db *sql.DB, userID, id int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	if _, err := getPlaylistFor(tx, userID, id); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return ErrPlaylistNotYours
		}
		return err
	}

	if _, err := tx.Exec(`DELETE FROM playlist_song WHERE playlist_id = ?`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM playlist WHERE id = ?`, id); err != nil {
		return err
	}
	return tx.Commit()
}

// writePlaylistError turns what a playlist function reported into the answer. Only the
// reasons above are named; anything else is a database failure and stays unnamed.
func writePlaylistError(w http.ResponseWriter, err error) {
	var slot *positionNotThere

	switch {
	case errors.Is(err, ErrPlaylistNotYours), errors.Is(err, sql.ErrNoRows):
		writeError(w, http.StatusNotFound, ErrPlaylistNotYours.Error())
	case errors.Is(err, ErrSongNotInLibrary):
		writeError(w, http.StatusNotFound, ErrSongNotInLibrary.Error())
	case errors.Is(err, ErrPlaylistFull):
		writeError(w, http.StatusBadRequest, ErrPlaylistFull.Error())
	case errors.As(err, &slot):
		writeError(w, http.StatusNotFound, slot.Error())
	default:
		writeError(w, http.StatusInternalServerError, "the playlist could not be read")
	}
}

// playlistRequest is the JSON body of POST /api/playlists.
type playlistRequest struct {
	Name string `json:"name"`
}

// songRequest is the JSON body of POST /api/playlists/{id}/songs and
// POST /api/queue/songs. track_id is a library id, so it is the same number the list
// endpoint shows.
type songRequest struct {
	TrackID int64 `json:"track_id"`
}

// readJSONBody decodes one strict JSON object of at most maxBodyBytes. The field named
// in the message is what this endpoint expects, so the answer names it. Every playlist
// and queue endpoint reads its body this way, so they reject the same things the
// register endpoint does: a second object, an unknown field, a body over the limit.
func readJSONBody(w http.ResponseWriter, r *http.Request, target any, field string) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)

	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(target); err != nil {
		writeError(w, http.StatusBadRequest, "body must be one JSON object with \""+field+"\"")
		return false
	}
	if dec.More() {
		writeError(w, http.StatusBadRequest, "body must contain exactly one JSON object")
		return false
	}
	return true
}

// pathPositiveID reads a path value that must be a plain positive number, the same rule
// as a song id. variable is the name in the route pattern ({id}, {position}); label is
// what the answer calls it. "0" or "-1" is not a position, and "0004" would be the same
// slot under two names.
func pathPositiveID(w http.ResponseWriter, r *http.Request, variable, label string) (int64, bool) {
	value := r.PathValue(variable)
	if !positiveIDPattern.MatchString(value) {
		writeError(w, http.StatusBadRequest, "the "+label+" must be a positive number")
		return 0, false
	}

	id, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		// The characters are digits, so this can only be a value too large to be an id,
		// and the answer must say that instead of "not a number".
		writeError(w, http.StatusBadRequest, "the "+label+" is too large")
		return 0, false
	}
	return id, true
}

// limitCheck is the shared rate-limit answer. A handler that is not allowed to answer
// stops here, so every endpoint in this file says the same thing about a full bucket.
func limitCheck(w http.ResponseWriter, r *http.Request, limiter *rateLimiter) bool {
	if ok, retry := limiter.allow(clientIP(r)); !ok {
		w.Header().Set("Retry-After", strconv.Itoa(retry))
		writeError(w, http.StatusTooManyRequests, "too many requests from this address, try again later")
		return false
	}
	return true
}

// createPlaylistHandler answers POST /api/playlists for a logged-in user.
func createPlaylistHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		var req playlistRequest
		if !readJSONBody(w, r, &req, "name") {
			return
		}

		name, ok := cleanPlaylistName(req.Name)
		if !ok {
			writeError(w, http.StatusBadRequest, ErrPlaylistNameTooLong.Error())
			return
		}
		if name == "" {
			writeError(w, http.StatusBadRequest, "the playlist needs a name")
			return
		}

		playlist, err := CreatePlaylist(db, user.ID, name)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "the playlist could not be read")
			return
		}

		writeJSON(w, http.StatusCreated, playlist)
	}
}

// listPlaylistsHandler answers GET /api/playlists: the caller's own playlists.
func listPlaylistsHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		playlists, err := ListPlaylists(db, user.ID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "the playlist could not be read")
			return
		}

		writeJSON(w, http.StatusOK, playlists)
	}
}

// getPlaylistHandler answers GET /api/playlists/{id} with the playlist and its songs.
func getPlaylistHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		id, ok := pathPositiveID(w, r, "id", "playlist id")
		if !ok {
			return
		}

		playlist, err := GetPlaylist(db, user.ID, id)
		if err != nil {
			writePlaylistError(w, err)
			return
		}

		writeJSON(w, http.StatusOK, playlist)
	}
}

// addPlaylistSongHandler answers POST /api/playlists/{id}/songs with
// {"track_id": <library id>}. The song is added at the end, and the answer says which
// position it got.
func addPlaylistSongHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		id, ok := pathPositiveID(w, r, "id", "playlist id")
		if !ok {
			return
		}

		var req songRequest
		if !readJSONBody(w, r, &req, "track_id") {
			return
		}
		if req.TrackID <= 0 {
			writeError(w, http.StatusBadRequest, "track_id must be a positive number")
			return
		}

		song, err := AddPlaylistSong(db, user.ID, id, req.TrackID)
		if err != nil {
			writePlaylistError(w, err)
			return
		}

		writeJSON(w, http.StatusCreated, song)
	}
}

// removePlaylistSongHandler answers DELETE /api/playlists/{id}/songs/{position}. The
// songs after the removed one are renumbered, so the remaining positions stay 1..n. A
// 204 has no body.
func removePlaylistSongHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		id, ok := pathPositiveID(w, r, "id", "playlist id")
		if !ok {
			return
		}
		position, ok := pathPositiveID(w, r, "position", "position")
		if !ok {
			return
		}

		if err := RemovePlaylistSong(db, user.ID, id, position); err != nil {
			writePlaylistError(w, err)
			return
		}

		writeNoContent(w)
	}
}

// deletePlaylistHandler answers DELETE /api/playlists/{id}. The songs stay in the shared
// library.
func deletePlaylistHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		id, ok := pathPositiveID(w, r, "id", "playlist id")
		if !ok {
			return
		}

		if err := DeletePlaylist(db, user.ID, id); err != nil {
			writePlaylistError(w, err)
			return
		}

		writeNoContent(w)
	}
}
