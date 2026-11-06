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

	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", registerHandler(db, registerLimiter))
	mux.HandleFunc("POST /api/login", loginHandler(db, loginLimiter))
	mux.HandleFunc("GET /api/session", sessionHandler(db, sessionLimiter))
	mux.HandleFunc("POST /api/music/upload", uploadHandler(db, library, uploadLimiter))

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
