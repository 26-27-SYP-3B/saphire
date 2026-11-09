package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/joho/godotenv"
	_ "modernc.org/sqlite"
)

func main() {
	_ = godotenv.Load()

	db, err := OpenDB()
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	// The shared music library folder, created here so uploads always have a
	// place to go. Every user's songs land in the same folder.
	library, err := OpenLibrary()
	if err != nil {
		log.Fatalf("library: %v", err)
	}

	// Rate limits: 5 requests per IP, refilling one token every 12s. Separate
	// buckets per endpoint so a login flood cannot starve registration requests.
	registerLimiter := newRateLimiter(5, 12*time.Second)
	loginLimiter := newRateLimiter(5, 12*time.Second)
	sessionLimiter := newRateLimiter(10, 12*time.Second)
	// Uploads move whole files, so this bucket is smaller on purpose.
	uploadLimiter := newRateLimiter(3, 30*time.Second)
	// Reading the library and streaming one song are their own buckets, so a client
	// that polls the list cannot starve playback, and a player that opens several
	// songs cannot starve the session checks.
	libraryLimiter := newRateLimiter(10, 12*time.Second)
	streamLimiter := newRateLimiter(10, 10*time.Second)
	// Playlists and the queue are separate from each other and from the library: a
	// client that builds a playlist should not be able to stop playback, and a player
	// that reads its queue should not be able to stop the library.
	playlistLimiter := newRateLimiter(10, 12*time.Second)
	queueLimiter := newRateLimiter(10, 12*time.Second)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", registerHandler(db, registerLimiter))
	mux.HandleFunc("POST /api/login", loginHandler(db, loginLimiter))
	mux.HandleFunc("GET /api/session", sessionHandler(db, sessionLimiter))
	mux.HandleFunc("POST /api/music/upload", uploadHandler(db, library, uploadLimiter))
	mux.HandleFunc("GET /api/music", listHandler(db, libraryLimiter))
	mux.HandleFunc("GET /api/music/{id}", streamHandler(db, library, streamLimiter))

	// Playlists belong to the user who created them. The queue is the same shape for
	// every source: filling it from a playlist is one of its sources, so a plain queue
	// feature later is another branch in queueSongIDs, not a new endpoint.
	mux.HandleFunc("POST /api/playlists", createPlaylistHandler(db, playlistLimiter))
	mux.HandleFunc("GET /api/playlists", listPlaylistsHandler(db, playlistLimiter))
	mux.HandleFunc("GET /api/playlists/{id}", getPlaylistHandler(db, playlistLimiter))
	mux.HandleFunc("POST /api/playlists/{id}/songs", addPlaylistSongHandler(db, playlistLimiter))
	mux.HandleFunc("DELETE /api/playlists/{id}/songs/{position}", removePlaylistSongHandler(db, playlistLimiter))
	mux.HandleFunc("DELETE /api/playlists/{id}", deletePlaylistHandler(db, playlistLimiter))

	mux.HandleFunc("POST /api/queue", fillQueueHandler(db, queueLimiter))
	mux.HandleFunc("GET /api/queue", getQueueHandler(db, queueLimiter))
	mux.HandleFunc("POST /api/queue/songs", appendQueueEntryHandler(db, queueLimiter))
	mux.HandleFunc("DELETE /api/queue/{position}", removeQueueEntryHandler(db, queueLimiter))
	mux.HandleFunc("DELETE /api/queue", clearQueueHandler(db, queueLimiter))

	// The development frontend in static/, mounted under its own prefix so it cannot
	// take over a path an API pattern owns. See static.go.
	mux.Handle("GET /static/", http.StripPrefix("/static", staticHandler(staticDir)))

	// The root pattern here is the exact "/" only ({$}), not a wildcard, so the API
	// keeps its own answers. It just forwards an open browser tab to the page.
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/static/", http.StatusMovedPermanently)
	})

	addr := fmt.Sprintf("0.0.0.0:%s", port)
	fmt.Printf("Listening on port %s\n", port)
	if err := http.ListenAndServe(addr, corsMiddleware(mux)); err != nil {
		log.Fatalf("server: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError sends the {"error": "…"} body that the client form shows below its fields.
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

// writeNoContent answers a successful delete. There is no body, so the JSON content
// type must not be set: a 204 with Content-Type: application/json and no body is what
// a client has to read as "nothing to parse".
func writeNoContent(w http.ResponseWriter) {
	w.WriteHeader(http.StatusNoContent)
}
