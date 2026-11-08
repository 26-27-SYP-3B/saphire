package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

func testStaticDir(t *testing.T) string {
	dir := t.TempDir()
	files := map[string]string{
		"index.html": `<!doctype html><title>Saphire dev console</title>`,
		"app.js":     `console.log("dev console");`,
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return dir
}

// mounted is the combination main.go runs with.
func mounted(dir string) http.Handler {
	return http.StripPrefix("/static", staticHandler(dir))
}

func TestStaticFrontend(t *testing.T) {
	handler := mounted(testStaticDir(t))

	cases := []struct {
		path        string
		status      int
		contentType string
	}{
		{"/static/", http.StatusOK, "text/html"},
		// The index file redirects to its folder, so the page has one address. See
		// the test below.
		{"/static/index.html", http.StatusMovedPermanently, ""},
		{"/static/app.js", http.StatusOK, "javascript"},
		{"/static/missing.html", http.StatusNotFound, ""},
	}

	for _, c := range cases {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, c.path, nil))

		if rec.Code != c.status {
			t.Errorf("GET %s -> %d, wanted %d (%s)", c.path, rec.Code, c.status, rec.Body)
			continue
		}
		if c.contentType != "" && !strings.Contains(rec.Header().Get("Content-Type"), c.contentType) {
			t.Errorf("GET %s served as %q, wanted %s", c.path, rec.Header().Get("Content-Type"), c.contentType)
		}
		if rec.Header().Get("X-Content-Type-Options") != "nosniff" {
			t.Errorf("GET %s without nosniff: %v", c.path, rec.Header())
		}
	}
}

// http.FileServer answers a path ending in index.html with a redirect to its
// folder. Under the mount that is the page address, so a link in the HTML must not
// quietly point at a redirect.
func TestStaticIndexRedirectsToThePageRoot(t *testing.T) {
	rec := httptest.NewRecorder()
	mounted(testStaticDir(t)).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/index.html", nil))

	if rec.Code != http.StatusMovedPermanently {
		t.Fatalf("GET /static/index.html -> %d, wanted 301 (%s)", rec.Code, rec.Body)
	}
	if rec.Header().Get("Location") != "./" {
		t.Errorf("redirect went to %q, wanted the page address", rec.Header().Get("Location"))
	}
}

// The page must not take over a path an API pattern owns. This is why it is mounted
// under a prefix instead of at "/": a wrong-method request to an endpoint stays the
// method answer the API documents.
func TestStaticFrontendDoesNotShadowTheApi(t *testing.T) {
	t.Setenv("SAPHIRE_DB_PATH", ":memory:")
	db, err := OpenDB()
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", registerHandler(db, newRateLimiter(100, time.Second)))
	mux.Handle("GET /static/", mounted(testStaticDir(t)))

	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/api/register", strings.NewReader(`{"username": "testuser", "password": "geheim123"}`)))
	if rec.Code != http.StatusCreated {
		t.Errorf("register through the mux -> %d, wanted 201 (%s)", rec.Code, rec.Body)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/register", nil))
	if rec.Code != http.StatusMethodNotAllowed || !strings.Contains(rec.Header().Get("Allow"), http.MethodPost) {
		t.Errorf("GET /api/register -> %d with Allow %q, wanted 405 allowing POST (%s)", rec.Code, rec.Header().Get("Allow"), rec.Body)
	}

	// Only GET serves the page.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/static/", strings.NewReader("{}")))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST /static/ -> %d, wanted 405 (%s)", rec.Code, rec.Body)
	}

	// The page itself still answers, and nothing is served at the root.
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("GET /static/ -> %d, wanted 200 (%s)", rec.Code, rec.Body)
	}

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("GET / -> %d, wanted 404 (%s)", rec.Code, rec.Body)
	}
}

// The page links its own stylesheet and script, so those paths must resolve from
// the folder main.go serves (the tests run in the package directory, which is the
// same folder `just run` uses).
func TestStaticFrontendServesItsOwnAssets(t *testing.T) {
	handler := mounted(staticDir)

	for _, path := range []string{"/static/", "/static/style.css", "/static/app.js"} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("GET %s -> %d, wanted 200 (%s)", path, rec.Code, rec.Body)
		}
	}
}

// The page is mounted under a prefix, so its links must be relative to the page.
// An absolute "/app.js" is outside the mount: the browser gets the 404 as
// text/plain and refuses to run the script, so the page loads and does nothing.
func TestStaticFrontendLinksStayRelative(t *testing.T) {
	page, err := os.ReadFile(filepath.Join(staticDir, "index.html"))
	if err != nil {
		t.Fatalf("read the page: %v", err)
	}

	for _, link := range regexp.MustCompile(`(?:href|src)="([^"]*)"`).FindAllStringSubmatch(string(page), -1) {
		if strings.HasPrefix(link[1], "/") {
			t.Errorf("link %q is absolute; it must be relative to the page so it resolves under the mount", link[1])
		}
	}
}

// The file root is the folder itself: http.FileServer cleans the path before it
// opens a file, so a ".." element cannot select one above the folder. Through the
// mux a path that needs cleaning is redirected first, and following it still cannot
// serve a file from outside the folder.
func TestStaticFrontendStaysInItsFolder(t *testing.T) {
	dir := testStaticDir(t)
	parent := filepath.Dir(dir)
	if err := os.WriteFile(filepath.Join(parent, "outside.html"), []byte("<title>outside</title>"), 0o644); err != nil {
		t.Fatalf("write outside file: %v", err)
	}

	rec := httptest.NewRecorder()
	mounted(dir).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/../outside.html", nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("GET /static/../outside.html -> %d, wanted 404 (%s)", rec.Code, rec.Body)
	}

	mux := http.NewServeMux()
	mux.Handle("GET /static/", mounted(dir))

	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/static/../outside.html", nil))
	if rec.Code != http.StatusTemporaryRedirect {
		t.Fatalf("the mux answers an unclean path with %d, wanted 307 (%s)", rec.Code, rec.Body)
	}

	target := rec.Header().Get("Location")
	rec = httptest.NewRecorder()
	mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, target, nil))
	if rec.Code != http.StatusNotFound {
		t.Errorf("following the cleaned path %q served a file outside the folder (%s)", target, rec.Body)
	}
}
