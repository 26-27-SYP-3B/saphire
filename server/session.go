package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"net/http"
	"strings"
	"time"
)

// Session is a row of the "session" table. The token itself is never stored,
// only its SHA-256 hash: a leaked database must not hand out usable sessions.
// Lookups go through the hash as the primary key, so there is no
// string-comparison timing signal either.
type Session struct {
	TokenHash string `json:"-"`
	UserID    int64  `json:"-"`
	CreatedAt int64  `json:"created_at"`
	ExpiresAt int64  `json:"expires_at"`
}

// ErrSessionNotFound means the token is unknown, expired or was dropped.
var ErrSessionNotFound = errors.New("session not found")

// sessionTTL is how long a login stays valid. Short enough that a stolen token
// does not live forever, long enough for a normal school day.
const sessionTTL = 24 * time.Hour

// hashToken turns a raw token into its SHA-256 hex form, which is the primary key.
func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// newSessionToken returns 32 random bytes from crypto/rand as 64 hex characters.
// crypto/rand, not math/rand: tokens must not be predictable.
func newSessionToken() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// Insert saves the session.
func (s *Session) Insert(db *sql.DB) error {
	_, err := db.Exec(`INSERT INTO session (token_hash, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)`,
		s.TokenHash, s.UserID, s.CreatedAt, s.ExpiresAt)
	return err
}

// FindSession looks a raw token up by its hash and drops the row when it is
// expired (lazy cleanup, so expired sessions never answer).
func FindSession(db *sql.DB, token string) (*Session, error) {
	var s Session
	err := db.QueryRow(`SELECT token_hash, user_id, created_at, expires_at FROM session WHERE token_hash = ?`, hashToken(token)).
		Scan(&s.TokenHash, &s.UserID, &s.CreatedAt, &s.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrSessionNotFound
	}
	if err != nil {
		return nil, err
	}
	if time.Now().Unix() > s.ExpiresAt {
		_, _ = db.Exec(`DELETE FROM session WHERE token_hash = ?`, s.TokenHash)
		return nil, ErrSessionNotFound
	}
	return &s, nil
}

// authenticate resolves the "Authorization: Bearer <token>" header to the user
// the session belongs to. It returns (nil, status, message) when the request is
// not authenticated, so every endpoint answers protected requests with the same
// two messages as GET /api/session: one for a missing header, one for an unknown
// or expired token.
func authenticate(db *sql.DB, r *http.Request) (*User, int, string) {
	auth := r.Header.Get("Authorization")
	if !strings.HasPrefix(auth, "Bearer ") {
		return nil, http.StatusUnauthorized, "authorization header with a Bearer token is missing"
	}

	session, err := FindSession(db, strings.TrimPrefix(auth, "Bearer "))
	if err != nil {
		if errors.Is(err, ErrSessionNotFound) {
			return nil, http.StatusUnauthorized, "session is not valid or expired"
		}
		return nil, http.StatusInternalServerError, "could not load session"
	}

	user, err := GetUserByID(db, session.UserID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, http.StatusUnauthorized, "session is not valid or expired"
		}
		return nil, http.StatusInternalServerError, "could not load user"
	}
	return user, http.StatusOK, ""
}
