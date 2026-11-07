package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The root pattern is the exact root, so a browser tab opened at "/" reaches the
// page without the page taking over any API path. An API path answered with a method
// no endpoint serves keeps the method answer the API documents.
func TestRootRedirectsToThePageWithoutTakingOverApiPaths(t *testing.T) {
	t.Setenv("SAPHIRE_DB_PATH", ":memory:")
	db, err := OpenDB()
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", registerHandler(db, newRateLimiter(100, time.Second)))
	mux.Handle("GET /static/", http.StripPrefix("/static", staticHandler(staticDir)))
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/static/", http.StatusMovedPermanently)
	})

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "/static/" {
		t.Errorf("GET / -> %d with Location %q, wanted 301 to the page", rec.Code, rec.Header().Get("Location"))
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/register", nil))
	if rec.Code != http.StatusMethodNotAllowed || !strings.Contains(rec.Header().Get("Allow"), http.MethodPost) {
		t.Errorf("GET /api/register -> %d with Allow %q, wanted 405 allowing POST (%s)", rec.Code, rec.Header().Get("Allow"), rec.Body)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("GET /static/ -> %d, wanted 200 (%s)", rec.Code, rec.Body)
	}
}
