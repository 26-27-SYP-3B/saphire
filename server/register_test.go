package main

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
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
	// Big capacity so only the request bodies decide the status.
	handler := registerHandler(openTestDB(t), newRateLimiter(100, time.Second))

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
		{`{"username": "lukas", "password": "secure-pass-123"}`, http.StatusCreated},
		{`{"username": "LUKAS", "password": "another-password"}`, http.StatusConflict}, // case-insensitive uniqueness
		{`{"username": "nina", "password": "short"}`, http.StatusBadRequest},
		{`{"username": "nina", "password": "exactly-72-characters-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "extra": true}`, http.StatusBadRequest}, // 73 chars and unknown field
		{`{"username": "ma ria", "password": "valid-password"}`, http.StatusBadRequest},
		{`{"username": "ab", "password": "valid-password"}`, http.StatusBadRequest},
		{`not json`, http.StatusBadRequest},
	}

	for _, c := range cases {
		rec := post(c.body)
		if rec.Code != c.status {
			t.Errorf("POST %s -> %d, wanted %d (%s)", c.body, rec.Code, c.status, rec.Body)
		}
	}

	// The client form shows the id, so the answer has to carry it — but never the hash.
	rec := post(`{"username": "Nina.", "password": "valid-password"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("wanted 201, got %d (%s)", rec.Code, rec.Body)
	}

	var created User
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if created.ID == 0 {
		t.Errorf("answer has no id: %s", rec.Body)
	}
	if created.Username != "nina." {
		t.Errorf("username was not normalized to lowercase: %s", rec.Body)
	}
	if strings.Contains(rec.Body.String(), "password") {
		t.Errorf("answer must not contain the password hash: %s", rec.Body)
	}
}

func TestRegisterRateLimit(t *testing.T) {
	handler := registerHandler(openTestDB(t), newRateLimiter(2, time.Second))

	post := func(username string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader(`{"username": "`+username+`", "password": "valid-password"}`))
		handler.ServeHTTP(rec, request)
		return rec
	}

	for i := 0; i < 2; i++ {
		if rec := post("user" + string(rune('a'+i))); rec.Code != http.StatusCreated {
			t.Fatalf("request %d -> %d, wanted 201 (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := post("userzz")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third request -> %d, wanted 429 (%s)", rec.Code, rec.Body)
	}
	if rec.Header().Get("Retry-After") != "60" {
		t.Errorf("missing Retry-After header")
	}
}
