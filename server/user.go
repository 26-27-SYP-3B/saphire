package main

import (
	"database/sql"
	"fmt"
	"os"
)

// User is a row of the "user" table.
type User struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Email string `json:"email"`
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

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS user (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			name TEXT NOT NULL,
			email TEXT NOT NULL
		)`)
	if err != nil {
		db.Close()
		return nil, err
	}

	return db, nil
}

// Insert saves the user and fills in its ID.
func (u *User) Insert(db *sql.DB) error {
	res, err := db.Exec(`INSERT INTO user (name, email) VALUES (?, ?)`, u.Name, u.Email)
	if err != nil {
		return err
	}
	u.ID, err = res.LastInsertId()
	if err != nil {
		return fmt.Errorf("last insert id: %w", err)
	}
	return nil
}
