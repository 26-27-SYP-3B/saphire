# Saphire Server


Compile the server for your Arch. / OS
```bash
go build -o build/saphire-server .
```
Run the server

```bash
./build/saphire-server
```

## Endpoints

`POST /api/register` — register a user with username + password only:

```bash
curl -X POST localhost:8080/api/register \
  -d '{"username": "lukas", "password": "secure-pass-123"}'
```

Returns `201 Created` with `{"id": 1, "username": "lukas"}`, `400` for invalid
input, `409` if the username is taken, `429` when rate limited. Passwords are
stored as bcrypt hashes (cost 12) and never returned. Note: the database schema
changed (username/password instead of name/email); delete an old `saphire.db`
before running.

`POST /api/login` — verifies the password and creates a session token (stored
only as its SHA-256 hash, 24 h TTL). `GET /api/session` with
`Authorization: Bearer <token>` returns the user the token belongs to. Full API
documentation: `api-docs.md` in the project root.

`POST /api/music/upload` — only a logged-in user may upload. The file goes into
the shared library folder (`SAPHIRE_LIBRARY_PATH`, default `library`, created on
startup) and a row in the `track` table, so the library is the same for every
user. Send the file as a form field named `file`:

```bash
curl -X POST localhost:8080/api/music/upload \
  -H "Authorization: Bearer <token>" \
  -F "file=@song.mp3"
```

Returns `201 Created` with the track record, `401` for anonymous requests,
`400` for a non-audio or empty file, `413` above 500 MiB, `429` when rate limited.

`GET /api/music` — the library as `id` and `title` for any logged-in user, ordered by
id. `GET /api/music/{id}` — one song, streamed in 32 KiB chunks with a flush after
each, so a player gets the start of a file before the rest is read. Both need the
same `Authorization: Bearer` rule as `GET /api/session`.

## Development frontend

Run the server from `server/` and open <http://localhost:8080/> (it forwards to
`/static/`) — `main.go` serves a plain HTML page (`static/`) for calling these
endpoints from a browser: register, login, session check, upload, list, stream. It
prints the status code, the elapsed time, `Retry-After`, and the same request as a
`curl` command; for the stream it shows which chunks arrived and when. Nothing on the
page checks the fields first (the file picker is filtered to the accepted extensions),
so what shows is what the server answered. The page is served under its own prefix so
an API route keeps the answers documented in `api-docs.md`, and the path is relative to
the folder the server is started from.
