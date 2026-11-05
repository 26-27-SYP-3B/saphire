package main

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/mail"
	"strings"
)

// registerHandler answers POST /api/register with the JSON body {"name": ..., "email": ...}.
// This is the trust boundary: the client form only checks the fields roughly, here the
// values become valid or the request is rejected.
func registerHandler(db *sql.DB) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var user User
		if err := json.NewDecoder(r.Body).Decode(&user); err != nil {
			writeError(w, http.StatusBadRequest, "body must be JSON with name and email")
			return
		}

		user.Name = strings.TrimSpace(user.Name)
		user.Email = strings.TrimSpace(user.Email)

		if user.Name == "" {
			writeError(w, http.StatusBadRequest, "name is missing")
			return
		}
		if _, err := mail.ParseAddress(user.Email); err != nil {
			writeError(w, http.StatusBadRequest, "email is not a valid address")
			return
		}

		// shortcut: reading then inserting is not atomic, so two requests can take the
		// same address at the same time. Upgrade: UNIQUE index on email, then INSERT alone.
		var takenID int64
		err := db.QueryRow(`SELECT id FROM user WHERE email = ?`, user.Email).Scan(&takenID)
		if err == nil {
			writeError(w, http.StatusConflict, "email is already registered")
			return
		}
		if !errors.Is(err, sql.ErrNoRows) {
			writeError(w, http.StatusInternalServerError, "database: "+err.Error())
			return
		}

		if err := user.Insert(db); err != nil {
			writeError(w, http.StatusInternalServerError, "insert user: "+err.Error())
			return
		}

		writeJSON(w, http.StatusCreated, user)
	}
}
