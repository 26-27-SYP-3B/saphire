package main

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"time"
)

// maxQueueEntries bounds one queue. A queue is read on every change, so an uncapped
// one would make one answer as large as the whole library. 200 is far above what a
// player needs at one time.
const maxQueueEntries = 200

// ErrQueueFull is the same limit seen from the other side: adding past it is refused
// rather than silently dropping the song.
var ErrQueueFull = errors.New("the queue holds at most " + strconv.Itoa(maxQueueEntries) + " songs")

// QueueEntry is one row of "queue_entry": a song at a position in one user's queue.
// The queue stores only the order and the songs. It does not store what filled it,
// because a queue must be fillable from anything: a playlist today, search results or a
// single song later. That is what makes a plain queue feature a UI job later, not a
// redesign here.
type QueueEntry struct {
	Position int    `json:"position"`
	TrackID  int64  `json:"track_id"`
	Title    string `json:"title"`
}

// queueRequest is the JSON body of POST /api/queue: which source fills the queue.
// source_id is needed for a playlist or a single song; for the whole library the source
// alone is enough, so sending it there is refused rather than ignored. It is a pointer so
// that "not sent" and "sent as 0" are different things — a plain int64 cannot tell them
// apart, and 0 would look like a field that was never sent.
type queueRequest struct {
	Source   string `json:"source"`
	SourceID *int64 `json:"source_id"`
}

// queueSources are the places a queue can be filled from. Adding one later means one
// branch in queueSongIDs; nothing else about a queue changes.
var queueSources = map[string]bool{
	"playlist": true, // the songs of one playlist, in its order
	"library":  true, // every song in the shared library, ordered by id
	"track":    true, // one song by itself
}

// ensureQueueTable creates the queue table. Called from OpenDB so tests get the same
// schema as the server.
func ensureQueueTable(db *sql.DB) error {
	_, err := db.Exec(`
		CREATE TABLE IF NOT EXISTS queue_entry (
			user_id INTEGER NOT NULL REFERENCES user(id),
			position INTEGER NOT NULL,
			track_id INTEGER NOT NULL REFERENCES track(id),
			added_at INTEGER NOT NULL
		)`)
	return err
}

// queueSongIDs resolves a source into the library ids a queue would be filled with, in
// the order the source gives. This is the universal part: every source becomes an
// ordered list of song ids, and filling a queue is the same work after that.
func queueSongIDs(q queryRunner, userID int64, source string, sourceID int64) ([]int64, error) {
	var query string
	var args []any

	switch source {
	case "playlist":
		// Only the caller's own playlist can fill a queue, the same rule as reading it.
		var owned int
		err := q.QueryRow(`SELECT 1 FROM playlist WHERE id = ? AND user_id = ?`, sourceID, userID).Scan(&owned)
		if errors.Is(err, sql.ErrNoRows) {
			return nil, ErrPlaylistNotYours
		}
		if err != nil {
			return nil, err
		}

		// The limit is read as part of the query, so a source larger than a queue is not
		// materialised in memory just to be refused.
		query = `SELECT track_id FROM playlist_song WHERE playlist_id = ? ORDER BY position LIMIT ` + strconv.Itoa(maxQueueEntries+1)
		args = []any{sourceID}
	case "library":
		query = `SELECT id FROM track ORDER BY id LIMIT ` + strconv.Itoa(maxQueueEntries+1)
	case "track":
		// A single song is a source like any other, and an unknown one is answered as the
		// missing song it is — not as an empty queue, which would quietly wipe the queue.
		var id int64
		if err := q.QueryRow(`SELECT id FROM track WHERE id = ?`, sourceID).Scan(&id); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				return nil, ErrSongNotInLibrary
			}
			return nil, err
		}
		return []int64{id}, nil
	default:
		return nil, errors.New("source must be \"playlist\", \"library\" or \"track\"")
	}

	rows, err := q.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	ids := []int64{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(ids) > maxQueueEntries {
		return nil, ErrQueueFull
	}
	// An empty source fills an empty queue: that is what a playlist with no songs
	// means, and the client already shows an empty queue. It is not an error.
	return ids, nil
}

// FillQueue replaces a queue with the songs of one source, in the order that source
// gives. Deleting and inserting happen in one transaction, so a queue is never seen as
// the old source with the new one partly added.
func FillQueue(db *sql.DB, userID int64, source string, sourceID int64) ([]QueueEntry, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	ids, err := queueSongIDs(tx, userID, source, sourceID)
	if err != nil {
		return nil, err
	}

	if _, err := tx.Exec(`DELETE FROM queue_entry WHERE user_id = ?`, userID); err != nil {
		return nil, err
	}

	now := time.Now().Unix()
	for i, id := range ids {
		if _, err := tx.Exec(`INSERT INTO queue_entry (user_id, position, track_id, added_at) VALUES (?, ?, ?, ?)`,
			userID, i+1, id, now); err != nil {
			return nil, err
		}
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return GetQueue(db, userID)
}

// AppendQueueEntry adds one song at the end of a queue and returns the position it got.
// This is the plain queue feature: fill a queue from a source, or add one song.
func AppendQueueEntry(db *sql.DB, userID, trackID int64) (*QueueEntry, error) {
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	var count int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM queue_entry WHERE user_id = ?`, userID).Scan(&count); err != nil {
		return nil, err
	}
	if count >= maxQueueEntries {
		return nil, ErrQueueFull
	}

	var title string
	err = tx.QueryRow(`SELECT title FROM track WHERE id = ?`, trackID).Scan(&title)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSongNotInLibrary
	}
	if err != nil {
		return nil, err
	}

	position := count + 1
	if _, err := tx.Exec(`INSERT INTO queue_entry (user_id, position, track_id, added_at) VALUES (?, ?, ?, ?)`,
		userID, position, trackID, time.Now().Unix()); err != nil {
		return nil, err
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return &QueueEntry{Position: position, TrackID: trackID, Title: title}, nil
}

// RemoveQueueEntry takes one position out of a queue and renumbers the songs after it,
// so the positions a client sees stay 1..n with no gaps.
func RemoveQueueEntry(db *sql.DB, userID, position int64) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	res, err := tx.Exec(`DELETE FROM queue_entry WHERE user_id = ? AND position = ?`, userID, position)
	if err != nil {
		return err
	}

	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return &positionNotThere{container: "queue", position: position}
	}

	if _, err := tx.Exec(`UPDATE queue_entry SET position = position - 1 WHERE user_id = ? AND position > ?`,
		userID, position); err != nil {
		return err
	}

	return tx.Commit()
}

// ClearQueue empties a queue. The songs stay in the library.
func ClearQueue(db *sql.DB, userID int64) error {
	_, err := db.Exec(`DELETE FROM queue_entry WHERE user_id = ?`, userID)
	return err
}

// GetQueue returns one user's queue in order. An empty queue answers [], not null.
func GetQueue(db *sql.DB, userID int64) ([]QueueEntry, error) {
	rows, err := db.Query(`
		SELECT q.position, q.track_id, t.title
		FROM queue_entry q JOIN track t ON t.id = q.track_id
		WHERE q.user_id = ? ORDER BY q.position`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	entries := []QueueEntry{}
	for rows.Next() {
		var e QueueEntry
		if err := rows.Scan(&e.Position, &e.TrackID, &e.Title); err != nil {
			return nil, err
		}
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return entries, nil
}

// writeQueueError names what a queue function reported. Like the playlist answers, it
// says what happened and the fix, and never a driver error.
func writeQueueError(w http.ResponseWriter, err error) {
	var slot *positionNotThere

	switch {
	case errors.Is(err, ErrPlaylistNotYours):
		writeError(w, http.StatusNotFound, ErrPlaylistNotYours.Error())
	case errors.Is(err, ErrSongNotInLibrary):
		writeError(w, http.StatusNotFound, ErrSongNotInLibrary.Error())
	case errors.Is(err, ErrQueueFull):
		writeError(w, http.StatusBadRequest, ErrQueueFull.Error())
	case errors.As(err, &slot):
		writeError(w, http.StatusNotFound, slot.Error())
	default:
		writeError(w, http.StatusInternalServerError, "the queue could not be read")
	}
}

// fillQueueHandler answers POST /api/queue: replace the caller's queue with one source.
// This is what "start a playlist" means: the playlist is a source, the queue is filled
// from it, and the player only ever reads a queue.
func fillQueueHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		var req queueRequest
		if !readJSONBody(w, r, &req, "source") {
			return
		}

		if !queueSources[req.Source] {
			writeError(w, http.StatusBadRequest, "source must be \"playlist\", \"library\" or \"track\"")
			return
		}
		if req.Source == "library" && req.SourceID != nil {
			// The whole library names nothing, so a source_id there is not ignored: it is
			// refused, because the caller meant something else.
			writeError(w, http.StatusBadRequest, "source_id is not used for the whole library")
			return
		}
		// A source that names something needs a real id. "Not sent" and "sent as 0" are
		// different things here, and both are refused the same way.
		if req.Source != "library" && (req.SourceID == nil || *req.SourceID <= 0) {
			writeError(w, http.StatusBadRequest, "source_id must be a positive number")
			return
		}

		var sourceID int64
		if req.SourceID != nil {
			sourceID = *req.SourceID
		}

		queue, err := FillQueue(db, user.ID, req.Source, sourceID)
		if err != nil {
			writeQueueError(w, err)
			return
		}

		writeJSON(w, http.StatusOK, queue)
	}
}

// getQueueHandler answers GET /api/queue: the caller's queue in order.
func getQueueHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		queue, err := GetQueue(db, user.ID)
		if err != nil {
			writeQueueError(w, err)
			return
		}

		writeJSON(w, http.StatusOK, queue)
	}
}

// appendQueueEntryHandler answers POST /api/queue/songs with {"track_id": <library id>}.
func appendQueueEntryHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
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

		entry, err := AppendQueueEntry(db, user.ID, req.TrackID)
		if err != nil {
			writeQueueError(w, err)
			return
		}

		writeJSON(w, http.StatusCreated, entry)
	}
}

// removeQueueEntryHandler answers DELETE /api/queue/{position}. The songs after it are
// renumbered. A 204 has no body.
func removeQueueEntryHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		position, ok := pathPositiveID(w, r, "position", "position")
		if !ok {
			return
		}

		if err := RemoveQueueEntry(db, user.ID, position); err != nil {
			writeQueueError(w, err)
			return
		}

		writeNoContent(w)
	}
}

// clearQueueHandler answers DELETE /api/queue.
func clearQueueHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limitCheck(w, r, limiter) {
			return
		}

		user, status, message := authenticate(db, r)
		if user == nil {
			writeError(w, status, message)
			return
		}

		if err := ClearQueue(db, user.ID); err != nil {
			writeQueueError(w, err)
			return
		}

		writeNoContent(w)
	}
}
