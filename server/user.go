package main

import (
	"database/sql"
	"fmt"
	"os"
)

// User is a row of the "user" table. Only username and password are stored;
// the password is kept as a bcrypt hash and never serialized to JSON.
type User struct {
	ID           int64  `json:"id"`
	Username     string `json:"username"`
	PasswordHash string `json:"-"`
}

// OpenDB opens the SQLite database from SAPHIRE_DB_PATH (default saphire.db)
// and makes sure the user table exists.
func OpenDB() (*sql.DB, error) {
	path := os.Getenv("SAPHIRE_DB_PATH")
	if path == "" {
		path = "saphire.db"
	}

	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}

	// Note: the schema changed (name/email -> username/password_hash). If an
	// old saphire.db exists, delete it or migrate it manually.
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS user (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			username TEXT NOT NULL UNIQUE,
			password_hash TEXT NOT NULL
		)`)
	if err != nil {
		db.Close()
		return nil, err
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS session (
			token_hash TEXT PRIMARY KEY,
			user_id INTEGER NOT NULL REFERENCES user(id),
			created_at INTEGER NOT NULL,
			expires_at INTEGER NOT NULL
		)`)
	if err != nil {
		db.Close()
		return nil, err
	}

	// The library table lives in music.go, its domain file.
	if err := ensureTrackTable(db); err != nil {
		db.Close()
		return nil, err
	}

	return db, nil
}

// GetUserByUsername finds a user by its normalized username. Returns
// sql.ErrNoRows when it does not exist. Always parameterized.
func GetUserByUsername(db *sql.DB, username string) (*User, error) {
	var u User
	err := db.QueryRow(`SELECT id, username, password_hash FROM user WHERE username = ?`, username).
		Scan(&u.ID, &u.Username, &u.PasswordHash)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// GetUserByID loads a user for a session lookup.
func GetUserByID(db *sql.DB, id int64) (*User, error) {
	var u User
	err := db.QueryRow(`SELECT id, username, password_hash FROM user WHERE id = ?`, id).
		Scan(&u.ID, &u.Username, &u.PasswordHash)
	if err != nil {
		return nil, err
	}
	return &u, nil
}

// Insert saves the user and fills in its ID. Returns ErrUsernameTaken when
// the username already exists (the UNIQUE constraint enforces this).
func (u *User) Insert(db *sql.DB) error {
	res, err := db.Exec(`INSERT INTO user (username, password_hash) VALUES (?, ?)`, u.Username, u.PasswordHash)
	if err != nil {
		if isUniqueConstraintError(err) {
			return ErrUsernameTaken
		}
		return err
	}
	u.ID, err = res.LastInsertId()
	if err != nil {
		return fmt.Errorf("last insert id: %w", err)
	}
	return nil
}
