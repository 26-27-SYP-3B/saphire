package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"

	"github.com/joho/godotenv"
	_ "modernc.org/sqlite"
)

func hello(w http.ResponseWriter, r *http.Request) {
	fmt.Println("Hello, world!")
	writeJSON(w, http.StatusOK, map[string]string{"message": "hello world"})
}

func main() {
	_ = godotenv.Load()

	db, err := OpenDB()
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer db.Close()

	newUser := &User{Name: "Lukas", Email: "lukas@example.at"}
	if err := newUser.Insert(db); err != nil {
		log.Fatalf("insert user: %v", err)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /", hello)
	mux.HandleFunc("POST /api/register", registerHandler(db))

	addr := fmt.Sprintf("0.0.0.0:%s", port)
	fmt.Printf("Listening on port %s\n", port)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server: %v", err)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// writeError sends the {"error": "…"} body that the client form shows below its fields.
func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
