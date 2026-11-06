package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The middleware wraps the mux, so the preflight and the real request must be
// tested through the same combination the server runs with.
func testMux(t *testing.T) http.Handler {
	t.Setenv("SAPHIRE_DB_PATH", ":memory:")
	db, err := OpenDB()
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", registerHandler(db, newRateLimiter(100, time.Second)))
	return corsMiddleware(mux)
}

func TestCorsPreflight(t *testing.T) {
	handler := testMux(t)

	rec := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodOptions, "/api/register", nil)
	request.Header.Set("Origin", "http://localhost:53736")
	request.Header.Set("Access-Control-Request-Method", "POST")
	handler.ServeHTTP(rec, request)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("preflight -> %d, wanted 204 (%s)", rec.Code, rec.Body)
	}
	if rec.Header().Get("Access-Control-Allow-Origin") != "http://localhost:53736" {
		t.Errorf("origin not reflected: %v", rec.Header())
	}
	if !strings.Contains(rec.Header().Get("Access-Control-Allow-Methods"), "POST") {
		t.Errorf("preflight must allow POST: %v", rec.Header())
	}
	if !strings.Contains(rec.Header().Get("Access-Control-Allow-Headers"), "Content-Type") {
		t.Errorf("preflight must allow the JSON content type: %v", rec.Header())
	}
	if rec.Header().Get("Vary") != "Origin" {
		t.Errorf("reflected origins need Vary: Origin so caches do not mix them: %v", rec.Header())
	}
}

// The real request needs its own header too; the preflight alone does not let
// the browser read the answer.
func TestCorsOnRealRequest(t *testing.T) {
	handler := testMux(t)

	rec := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader(`{"username": "testuser", "password": "geheim123"}`))
	request.Header.Set("Origin", "http://localhost:53736")
	handler.ServeHTTP(rec, request)

	if rec.Code != http.StatusCreated {
		t.Fatalf("register through the middleware -> %d, wanted 201 (%s)", rec.Code, rec.Body)
	}
	if rec.Header().Get("Access-Control-Allow-Origin") != "http://localhost:53736" {
		t.Errorf("real request without the origin header would be blocked in the browser: %v", rec.Header())
	}

	// A non-browser client sends no Origin: then no CORS headers belong on the
	// answer, and the endpoint must still work.
	rec = httptest.NewRecorder()
	request = httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader(`{"username": "otheruser", "password": "geheim123"}`))
	handler.ServeHTTP(rec, request)
	if rec.Code != http.StatusCreated {
		t.Fatalf("register without origin -> %d (%s)", rec.Code, rec.Body)
	}
	if rec.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Errorf("no origin was sent, so none should be answered: %v", rec.Header())
	}
}
