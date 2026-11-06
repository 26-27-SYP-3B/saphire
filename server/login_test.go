package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"
)

func TestLogin(t *testing.T) {
	db := openTestDB(t)
	handler := loginHandler(db, newRateLimiter(100, time.Second))

	post := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(body))
		handler.ServeHTTP(rec, request)
		return rec
	}

	cases := []struct {
		body   string
		status int
	}{
		{`{"username": "lukas", "password": "wrong-password"}`, http.StatusUnauthorized}, // unknown user and wrong password answer the same
		{`{"username": "LUKAS", "password": "wrong-password"}`, http.StatusUnauthorized}, // normalized before lookup
		{`{"username": "ab", "password": "valid-password"}`, http.StatusBadRequest},       // same field rules as registration
		{`{"username": "lukas", "password": "short"}`, http.StatusBadRequest},
		{`not json`, http.StatusBadRequest},
	}

	for _, c := range cases {
		rec := post(c.body)
		if rec.Code != c.status {
			t.Errorf("POST %s -> %d, wanted %d (%s)", c.body, rec.Code, c.status, rec.Body)
		}
	}

	// Register, then log in with the same credentials.
	register := registerHandler(db, newRateLimiter(100, time.Second))
	rec := httptest.NewRecorder()
	register.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/register",
		strings.NewReader(`{"username": "lukas", "password": "secure-pass-123"}`)))
	if rec.Code != http.StatusCreated {
		t.Fatalf("register -> %d (%s)", rec.Code, rec.Body)
	}

	rec = post(`{"username": "lukas", "password": "secure-pass-123"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("login -> %d, wanted 200 (%s)", rec.Code, rec.Body)
	}

	var login struct {
		Token     string `json:"token"`
		ExpiresAt int64  `json:"expires_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &login); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	// 32 random bytes as hex, nothing predictable about it.
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(login.Token) {
		t.Errorf("token is not 64 hex characters: %s", login.Token)
	}
	if login.ExpiresAt <= time.Now().Unix() || login.ExpiresAt > time.Now().Add(sessionTTL).Unix() {
		t.Errorf("expires_at is not within the session TTL: %d", login.ExpiresAt)
	}

	// The stored row holds only the hash, never the token itself.
	var stored string
	if err := db.QueryRow(`SELECT token_hash FROM session`).Scan(&stored); err != nil {
		t.Fatalf("read session: %v", err)
	}
	if stored != hashToken(login.Token) {
		t.Errorf("session stores %q, wanted the hash of the token", stored)
	}

	// The token authenticates at GET /api/session.
	session := sessionHandler(db, newRateLimiter(100, time.Second))
	rec = httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/session", nil)
	request.Header.Set("Authorization", "Bearer "+login.Token)
	session.ServeHTTP(rec, request)
	if rec.Code != http.StatusOK {
		t.Fatalf("session -> %d, wanted 200 (%s)", rec.Code, rec.Body)
	}

	var user User
	if err := json.Unmarshal(rec.Body.Bytes(), &user); err != nil {
		t.Fatalf("decode answer: %v", err)
	}
	if user.ID == 0 || user.Username != "lukas" {
		t.Errorf("session names the wrong user: %s", rec.Body)
	}
	if strings.Contains(rec.Body.String(), "password") {
		t.Errorf("answer must not contain the password hash: %s", rec.Body)
	}

	// A missing header is its own error, so the client knows what to fix.
	rec = httptest.NewRecorder()
	session.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/session", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("no header -> %d, wanted 401 (%s)", rec.Code, rec.Body)
	}

	// An expired session is refused and dropped from the table. The raw token
	// is used here because the hash cannot be turned back into one.
	rawToken := strings.Repeat("f", 64)
	expired := &Session{
		TokenHash: hashToken(rawToken),
		UserID:    user.ID,
		CreatedAt: time.Now().Add(-2 * sessionTTL).Unix(),
		ExpiresAt: time.Now().Add(-sessionTTL).Unix(),
	}
	if err := expired.Insert(db); err != nil {
		t.Fatalf("insert expired session: %v", err)
	}
	rec = httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodGet, "/api/session", nil)
	request.Header.Set("Authorization", "Bearer "+rawToken)
	session.ServeHTTP(rec, request)
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("expired session -> %d, wanted 401 (%s)", rec.Code, rec.Body)
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM session`).Scan(&count); err != nil {
		t.Fatalf("count sessions: %v", err)
	}
	if count != 1 {
		t.Errorf("expired session was not dropped, %d rows left", count)
	}
}

func TestLoginRateLimit(t *testing.T) {
	handler := loginHandler(openTestDB(t), newRateLimiter(2, time.Second))

	post := func(body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(body))
		handler.ServeHTTP(rec, request)
		return rec
	}

	// The first two are allowed even though they fail for other reasons — the
	// limiter decides first, so brute-force guessing is what costs tokens.
	for i := 0; i < 2; i++ {
		if rec := post(`{"username": "nobody", "password": "valid-password"}`); rec.Code != http.StatusUnauthorized {
			t.Fatalf("request %d -> %d, wanted 401 (%s)", i+1, rec.Code, rec.Body)
		}
	}

	rec := post(`{"username": "nobody", "password": "valid-password"}`)
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third request -> %d, wanted 429 (%s)", rec.Code, rec.Body)
	}
	if rec.Header().Get("Retry-After") != "60" {
		t.Errorf("missing Retry-After header")
	}
}
