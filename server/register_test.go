package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func openTestDB(t *testing.T) *sql.DB {
	t.Setenv("SAPHIRE_DB_PATH", ":memory:")

	db, err := OpenDB()
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	return db
}

func TestRegister(t *testing.T) {
	handler := registerHandler(openTestDB(t))

	post := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader(body))
		handler.ServeHTTP(rec, request)
		return rec
	}

	cases := []struct {
		body   string
		status int
	}{
		{`{"name": "Lukas", "email": "lukas@example.at"}`, http.StatusCreated},
		{`{"name": "Lukas", "email": "lukas@example.at"}`, http.StatusConflict},
		{`{"name": "  ", "email": "other@example.at"}`, http.StatusBadRequest},
		{`{"name": "Lukas", "email": "not an address"}`, http.StatusBadRequest},
		{`not json`, http.StatusBadRequest},
	}

	for _, c := range cases {
		rec := post(c.body)
		if rec.Code != c.status {
			t.Errorf("POST %s -> %d, wanted %d (%s)", c.body, rec.Code, c.status, rec.Body)
		}
	}

	// The client form shows the id, so the answer has to carry it.
	rec := post(`{"name": "Nina", "email": "nina@example.at"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("wanted 201, got %d (%s)", rec.Code, rec.Body)
	}

	var created User
	if err := json.NewDecoder(rec.Body).Decode(&created); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if created.ID == 0 {
		t.Errorf("answer has no id: %s", rec.Body)
	}
	if created.Email != "nina@example.at" {
		t.Errorf("answer has the wrong email: %s", rec.Body)
	}
}
