package main

import (
	"net/http"
)

// staticDir holds the development frontend: plain HTML, CSS and JS for calling the
// endpoints from a browser. The path is relative to the folder the server is
// started from (`just run` inside server/), so editing a file and reloading the
// page is enough — nothing here is compiled into the binary.
const staticDir = "static"

// staticHandler serves the development frontend. It is mounted under its own prefix
// rather than at "/": a pattern for "/" is a wildcard, so it would also answer
// /api/* for a method no endpoint serves, and a wrong-method request would then get
// the page's plain text 404 instead of the 405 the API documents.
//
// A missing file gets the plain text 404 of http.FileServer rather than the JSON
// error shape, because this is not an API endpoint. X-Content-Type-Options is still
// set, as on every other response from this server.
func staticHandler(dir string) http.Handler {
	files := http.FileServer(http.Dir(dir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		files.ServeHTTP(w, r)
	})
}
