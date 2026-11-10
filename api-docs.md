# Saphire API Documentation

Base URL: `http://localhost:8080` (port configurable via `PORT` in `.env`).

All responses are JSON with `Content-Type: application/json` and
`X-Content-Type-Options: nosniff`. Errors use a single shape:

```json
{ "error": "human readable description of what went wrong" }
```

Authenticated requests carry the session token in
`Authorization: Bearer <token>`.

Browser clients work because of a CORS middleware (`server/cors.go`): the
`Origin` is reflected on every answer, `OPTIONS` preflights get `204 No Content`
with the allowed methods and headers, and a request without an `Origin` (a plain
HTTP client) gets no CORS headers. On a phone or an Android emulator the default
`http://127.0.0.1:8080` does not reach the development machine — override
`API_BASE_URL` with `--dart-define`.

---

## Implemented

### `POST /api/register`

Registers a new user. Users have only a username and a password — no email or
other fields.

```
POST /api/register
Content-Type: application/json
```

**Request body**

```json
{
  "username": "user",
  "password": "secure-pass-123"
}
```

Exactly one JSON object with exactly these two fields. Unknown fields and
trailing content are rejected. Body is limited to 4 KiB.

**Input rules**

| Field | Rules |
|---|---|
| `username` | 3–32 characters; only `a-z`, `0-9`, `_`, `.`, `-`. Trimmed and lowercased, so `Lukas` and `lukas` are the same account. |
| `password` | 8–72 bytes, no control characters. 72 is the bcrypt limit — longer input is rejected instead of silently truncated. Stored only as a bcrypt hash (cost 12), never returned or logged. |

**Responses**

| Status | When | Example body |
|---|---|---|
| `201 Created` | User registered | `{"id": 1, "username": "lukas"}` |
| `400 Bad Request` | Malformed JSON, unknown fields, oversized body, or a username/password that fails the rules | `{"error": "password must be at least 8 characters"}` |
| `409 Conflict` | Username already taken | `{"error": "username is not available"}` |
| `429 Too Many Requests` | Rate limit reached (5 requests per IP, refilling 1 token every 12 s). Includes a `Retry-After` header with the seconds until the next token (never more than the 12 s refill window). | `{"error": "too many registrations from this address, try again later"}` |
| `500 Internal Server Error` | Hashing or database failure | `{"error": "could not save user"}` |

**Success example**

```bash
curl -X POST localhost:8080/api/register \
  -d '{"username": "lukas", "password": "secure-pass-123"}'
```

```json
{ "id": 1, "username": "lukas" }
```

**Notes**

- The password hash is never serialized to JSON (`json:"-"` on the model).
- Username existence checks are deliberately timed to not leak whether a
  username exists: the hash is computed before the insert is attempted.
- The rate limiter trusts `X-Forwarded-For` when running behind a reverse proxy.
  The peer address is split off the port with `net.SplitHostPort`, so IPv6 peers
  (bracketed `RemoteAddr`, including `::1`) get their own bucket rather than a
  shared one; stale buckets are pruned so the map stays bounded.
- Database schema:

  ```sql
  CREATE TABLE IF NOT EXISTS user (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL
  )
  ```

  The old `name`/`email` schema is not migrated; delete an existing `saphire.db`
  created before this change.

### `POST /api/login`

Logs in and creates a session. The same field rules as `POST /api/register`
apply (see the table above); the login rate limit is a separate bucket.

```
POST /api/login
Content-Type: application/json
```

**Request body**

```json
{
  "username": "lukas",
  "password": "secure-pass-123"
}
```

**Responses**

| Status | When | Example body |
|---|---|---|
| `200 OK` | Password verified, session created | `{"token": "9eb5…946c", "expires_at": 1794039606}` |
| `400 Bad Request` | Malformed JSON or fields that fail the input rules | same messages as `/api/register` |
| `401 Unauthorized` | Username unknown **or** password wrong — always the same answer, so callers cannot enumerate users | `{"error": "username or password is wrong"}` |
| `429 Too Many Requests` | Login rate limit reached. Includes a `Retry-After` header (seconds until the next token, at most the 12 s refill window). | `{"error": "too many logins from this address, try again later"}` |
| `500 Internal Server Error` | Database failure | `{"error": "could not load user"}` |

**Notes**

- The token is 32 random bytes from `crypto/rand` as 64 hex characters. It is
  only shown once, in this response; the database stores just its SHA-256 hash,
  so a leaked database does not hand out usable sessions.
- Sessions expire 24 hours after login (`sessionTTL`). Expired rows are dropped
  on the next lookup.
- Unknown users are answered with the same 401 after a comparison against a
  dummy hash, so the response time does not reveal whether a username exists.

### `GET /api/session`

Returns the user the presented token belongs to — this is how a client proves it
is logged in.

```
GET /api/session
Authorization: Bearer <token>
```

**Responses**

| Status | When | Example body |
|---|---|---|
| `200 OK` | Token valid and not expired | `{"id": 1, "username": "lukas"}` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token (the row is dropped), or the token's user no longer exists | `{"error": "session is not valid or expired"}` |
| `429 Too Many Requests` | Session rate limit reached. Includes a `Retry-After` header (seconds until the next token, at most the 12 s refill window). | `{"error": "too many requests from this address, try again later"}` |
| `500 Internal Server Error` | Database failure | `{"error": "could not load session"}` or `{"error": "could not load user"}` |

**Database schema for sessions**

```sql
CREATE TABLE IF NOT EXISTS session (
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES user(id),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
)
```

### `POST /api/music/upload`

Uploads one song into the music library. **Only a logged-in user may upload**;
anonymous requests are refused with the same two 401 messages as
`GET /api/session`. The library is one folder the server creates at startup
(`SAPHIRE_LIBRARY_PATH`, default `library`), so every uploaded song is available
to everyone — there is no per-user path.

```
POST /api/music/upload
Authorization: Bearer <token>
Content-Type: multipart/form-data
```

**Request**

The file is sent as a form field named `file`:

```bash
curl -X POST localhost:8080/api/music/upload \
  -H "Authorization: Bearer <token>" \
  -F "file=@song.mp3"
```

**Input rules**

| Part | Rules |
|---|---|
| `file` | Not empty, at most 500 MiB. Accepted audio extensions: `mp3`, `wav`, `m4a`, `ogg`, `opus`, `flac`, `aac`. If the content can be sniffed it must actually be audio, so a text file renamed `.mp3` is refused; formats the sniffer cannot name (M4A, Ogg, FLAC) are accepted on their extension. |
| name | Base name only, no control characters, at most 200 characters. An MP3 whose tags name a title (`TIT2`) uses that instead, so a file is titled by what it says about itself; the name is the fallback. The file itself is stored under a generated name (16 random bytes as hex + the extension), so no client name can escape the library folder and no upload overwrites another song. |

**Responses**

| Status | When | Example body |
|---|---|---|
| `201 Created` | File saved in the library and the row inserted | `{"id": 4, "uploaded_by": "lukas", "title": "Neutrone (Remix)", "artist": "Kraftwerk", "duration_ms": 261000, "stored_name": "18cfd7db41d243d98cc87c4ab33dded6.mp3", "size": 4237, "content_type": "audio/mpeg", "uploaded_at": 1793974311}` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token | `{"error": "session is not valid or expired"}` |
| `400 Bad Request` | Not `multipart/form-data`, no file, the field is not named `file`, an empty file, a name with no usable characters, or content that is not audio | `{"error": "only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)"}` |
| `413 Request Entity Too Large` | Upload larger than 500 MiB | `{"error": "upload is larger than 500 MiB"}` |
| `429 Too Many Requests` | Upload rate limit reached (3 requests per IP, refilling 1 token every 30 s — its own bucket). Includes a `Retry-After` header (seconds until the next token, at most the 30 s refill window). | `{"error": "too many uploads from this address, try again later"}` |
| `500 Internal Server Error` | Writing the file or inserting the row failed | `{"error": "could not save the file"}` |

**Notes**

- Authentication is checked before the body is read, so an anonymous caller
  cannot make the server read 500 MiB it would throw away.
- The file is written before the row is inserted; if the insert fails, the file
  is removed again, so a library entry never points at a missing file.
- `stored_name` is what the file is called inside the library folder;
  `GET /api/music/{id}` sends it back.
- `artist` and `duration_ms` are what the file says about itself (`server/metadata.go`):
  the `TPE1` tag and the length from the frame headers. Only MP3 can be measured from
  the bytes, so the other accepted containers keep `0`, and a file with no tags keeps an
  empty artist. A client shows a dash for those rather than a guess.
- Database schema:

  ```sql
  CREATE TABLE IF NOT EXISTS track (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL REFERENCES user(id),
      title TEXT NOT NULL,
      artist TEXT NOT NULL DEFAULT '',
      duration_ms INTEGER NOT NULL DEFAULT 0,
      stored_name TEXT NOT NULL UNIQUE,
      size INTEGER NOT NULL,
      content_type TEXT NOT NULL,
      uploaded_at INTEGER NOT NULL
  )
  ```

  A `saphire.db` created before these columns get them: `ensureTrackColumns` reads
  `PRAGMA table_info(track)` and adds the missing ones, so an old row keeps reading as
  an untagged file instead of failing.

### `GET /api/music`

Lists the library for a logged-in user. Every row is a track as `POST /api/music/upload`
answered it, including `uploaded_by`; the library is shared, so the list is the same for
every account.

```
GET /api/music
Authorization: Bearer <token>
```

**Responses**

| Status | When | Example body |
|---|---|---|
| `200 OK` | Rows read | `[{"id": 1, "uploaded_by": "lukas", "title": "Neutrone (Remix)", "artist": "Kraftwerk", "duration_ms": 261000, "stored_name": "18cfd7db…mp3", "size": 4237, "content_type": "audio/mpeg", "uploaded_at": 1793974311}]` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token | `{"error": "session is not valid or expired"}` |
| `429 Too Many Requests` | Library rate limit reached (10 requests per IP, refilling 1 token every 12 s — its own bucket, shared with `GET /api/music/{id}`). Includes a `Retry-After` header. | `{"error": "too many requests from this address, try again later"}` |
| `500 Internal Server Error` | Database failure | `{"error": "could not load the library"}` |

**Notes**

- An empty library answers `[]`, never `null`, so a client can tell an empty library
  apart from an answer it could not read.
- Rows come in the order they were added. Filtering and sorting are the client's job
  (the library screen does them), so there is no `?q=` or `?sort=` here, and nothing is
  paginated: one account's songs are a few hundred at most.
- Reading the library is a protected request: an anonymous caller gets the same two 401
  answers as `GET /api/session`, because the list shows account names.

```bash
curl localhost:8080/api/music -H "Authorization: Bearer <token>"
```

### `GET /api/music/{id}`

Serves the stored file for one row. This is what the player streams, so a successful
answer is the file itself — the only route here that does not answer the JSON shape —
while every error uses `{"error": "…"}`. Only the range error is different: that one is
written by `http.ServeFile` itself, as plain text.

```
GET /api/music/{id}
Authorization: Bearer <token>
```

**Responses**

| Status | When | What the answer is |
|---|---|---|
| `200 OK` | Row found and the file is in the library | the bytes, with the `Content-Type` recorded on the row, `Content-Length`, `Accept-Ranges: bytes`, and `Content-Disposition: inline; filename="<stored_name>"` |
| `206 Partial Content` | Request with a `Range` header | that part of the file, so a player can start before the whole song is read, plus `Content-Range: bytes <from>-<to>/<size>`. `Content-Disposition` is on this answer too |
| `400 Bad Request` | `id` is not a number | `{"error": "the song id must be a number"}` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token | `{"error": "session is not valid or expired"}` |
| `404 Not Found` | No row with that id | `{"error": "no song with that id"}` |
| `404 Not Found` | Row points at a file the library does not have | `{"error": "the file for this song is not in the library"}` |
| `416 Requested Range Not Satisfiable` | `Range` that cannot be read as a byte range (`bytes=abc`), or a range outside the file | plain text, not the JSON shape (`invalid range`), with `Content-Range: bytes */<size>` when the size is known |
| `429 Too Many Requests` | Library rate limit reached (the same bucket as `GET /api/music`) | `{"error": "too many requests from this address, try again later"}` |
| `500 Internal Server Error` | Database failure, or a stored name that is not a plain library file name | `{"error": "could not load the song"}` |

```bash
curl localhost:8080/api/music/4 -H "Authorization: Bearer <token>"
curl -D - localhost:8080/api/music/4 -H "Authorization: Bearer <token>" -H 'Range: bytes=0-100'
# a range outside the file answers 416, as plain text:
curl -i localhost:8080/api/music/4 -H "Authorization: Bearer <token>" -H 'Range: bytes=99999-100000'
```

---

## Upcoming

Beyond the endpoints above, nothing exists yet. Planned, in rough order:

- `POST /api/logout` — delete the session row for the presented token and
  answer `204 No Content`. Same `Authorization: Bearer` rule as
  `GET /api/session`; a client that keeps the token after logout should be
  refused with the same 401 message as an expired session.
- The client features (playlists, equalizer) have no API yet: a playlist is kept in the
  app (`client/lib/features/playlists/data/playlist_store.dart`), and the queue lives
  only in the player. When their endpoints are designed, they go under **Implemented**
  here — same status tables, same error shape.

---

## Development frontend

`server/static/` holds a plain HTML page for calling these endpoints from a browser
while they are being built. `main.go` serves it for `GET /static/` through
`static.go`, from the folder relative to the directory the server is started from
(`just run` inside `server/`); nothing is compiled into the binary, so editing a
file and reloading the page is enough.

It is mounted under its own prefix on purpose. A pattern for `/` is a wildcard, so it
would also answer `/api/*` for a method no endpoint serves, and a wrong-method request
would get the page's plain text 404 instead of the `405` the endpoints above document.
The root itself is the exact root pattern (`GET /{$}`), so it cannot take an API path
over; it only forwards a browser to the page.

These answers are not part of the API: they are `text/html`, `text/css` and
`text/javascript` (with `X-Content-Type-Options: nosniff`, like every other answer
from this server), and a missing file is the plain text `404 page not found` of
`http.FileServer` rather than the JSON error shape:

| Route | Status | What it answers |
|---|---|---|
| `GET /` | `301 Moved Permanently` | `Location: /static/`, so a tab opened at the root reaches the page |
| `GET /static/` | `200 OK` | `static/index.html` |
| `GET /static/index.html` | `301 Moved Permanently` | `Location: ./`, because `http.FileServer` treats the index file as its folder — the page has one address |
| `GET /static/style.css`, `GET /static/app.js` | `200 OK` | the files the page links |
| `GET /static/<anything else>` | `404 Not Found` | plain text `404 page not found` |
| `POST /static/` | `405 Method Not Allowed` | only GET serves the page |

The page sends exactly what is typed and shows what the server answered: the status
code, the elapsed time, `Retry-After` when a rate limit answers 429, and the same
request written as `curl`. It keeps the session token in `sessionStorage` for the
current tab and shows it from there — the raw token is still only ever returned by
`POST /api/login`, and the database still stores only its hash. On load the page calls
`GET /api/session` with the stored token, so the 401 path is visible
without logging in again.
