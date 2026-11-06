package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// dummyHash is compared when a login names an unknown user so the response time
// does not reveal whether the username exists — the same reasoning as the
// hash-before-insert order in register.go. Its value is meaningless.
var dummyHash = mustDummyHash()

func mustDummyHash() string {
	h, err := bcrypt.GenerateFromPassword([]byte("timing equalizer"), bcryptCost)
	if err != nil {
		panic("dummy hash: " + err.Error())
	}
	return string(h)
}

// loginHandler answers POST /api/login with {"username": ..., "password": ...}.
// On success it creates a session in the session table (only the token's hash
// is stored) and returns the raw token once, which is the only time the client
// ever sees it. Login takes the same fields and rules as registration;
// validateRegistration is the single source of those rules.
func loginHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if !limiter.allow(ip) {
			w.Header().Set("Retry-After", "60")
			writeError(w, http.StatusTooManyRequests, "too many logins from this address, try again later")
			return
		}

		// Strict request size limit and strict JSON parsing, as in register.go.
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		dec := json.NewDecoder(r.Body)
		dec.DisallowUnknownFields()

		var req RegistrationRequest
		if err := dec.Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "body must be one JSON object with \"username\" and \"password\"")
			return
		}
		if dec.More() {
			writeError(w, http.StatusBadRequest, "body must contain exactly one JSON object")
			return
		}

		req.Username = normalizeUsername(req.Username)
		if err := validateRegistration(&req); err != nil {
			writeError(w, http.StatusBadRequest, err.Error())
			return
		}

		// The 401 always says the same thing: it never distinguishes "no such
		// user" from "wrong password", so callers cannot enumerate usernames.
		user, err := GetUserByUsername(db, req.Username)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				_ = bcrypt.CompareHashAndPassword([]byte(dummyHash), []byte(req.Password))
				writeError(w, http.StatusUnauthorized, "username or password is wrong")
				return
			}
			writeError(w, http.StatusInternalServerError, "could not load user")
			return
		}

		// CompareHashAndPassword is constant time for a given hash length,
		// which is what a timing-safe password check needs.
		if bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)) != nil {
			writeError(w, http.StatusUnauthorized, "username or password is wrong")
			return
		}

		token, err := newSessionToken()
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not create session")
			return
		}

		now := time.Now()
		session := &Session{
			TokenHash: hashToken(token),
			UserID:    user.ID,
			CreatedAt: now.Unix(),
			ExpiresAt: now.Add(sessionTTL).Unix(),
		}
		if err := session.Insert(db); err != nil {
			writeError(w, http.StatusInternalServerError, "could not save session")
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"token":      token,
			"expires_at": session.ExpiresAt,
		})
	}
}

// sessionHandler answers GET /api/session for a request that carries
// "Authorization: Bearer <token>". This is how the client proves it is logged in.
func sessionHandler(db *sql.DB, limiter *rateLimiter) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !limiter.allow(clientIP(r)) {
			w.Header().Set("Retry-After", "60")
			writeError(w, http.StatusTooManyRequests, "too many requests from this address, try again later")
			return
		}

		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			writeError(w, http.StatusUnauthorized, "authorization header with a Bearer token is missing")
			return
		}
		token := strings.TrimPrefix(auth, "Bearer ")

		session, err := FindSession(db, token)
		if err != nil {
			if errors.Is(err, ErrSessionNotFound) {
				writeError(w, http.StatusUnauthorized, "session is not valid or expired")
				return
			}
			writeError(w, http.StatusInternalServerError, "could not load session")
			return
		}

		user, err := GetUserByID(db, session.UserID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "could not load user")
			return
		}

		writeJSON(w, http.StatusOK, user) // PasswordHash has json:"-", so it is not sent
	}
}
