package main

import (
	"net/http"
)

// corsMiddleware lets the browser client (flutter run -d chrome) talk to the
// API. A browser sends an OPTIONS preflight before a JSON POST and blocks the
// answer without Access-Control headers; the method patterns in main.go answer
// POST only, so the preflight has to be handled here.
//
// The Origin is reflected instead of wildcarded: that is safer (a wildcard
// grants every site access) and it is what a browser accepts when credentials
// are involved. Vary: Origin keeps caches correct when different origins
// reflect different answers.
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Add("Vary", "Origin")
		}

		if r.Method == http.MethodOptions {
			// Preflight: no body, just the permission to send the real request.
			h := w.Header()
			h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
			h.Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			h.Set("Access-Control-Max-Age", "600")
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}
