# Saphire API Documentation

Base URL: `http://localhost:8080` (port configurable via `PORT` in `.env`).

Every API answer is JSON with `Content-Type: application/json`, except
`GET /api/music/{id}`, which sends the file itself with the content type stored for that
song (there the JSON error shape applies only to the answers sent before the first byte),
and the plain text `404` for a path no endpoint defines — that path is not an endpoint, so
it has no error shape to answer with. `X-Content-Type-Options: nosniff` is on every answer
from this server, including the `OPTIONS` preflight and those plain text answers (see the
development frontend section). Errors use a single
shape:

```json
{ "error": "human readable description of what went wrong" }
```

Authenticated requests carry the session token in
`Authorization: Bearer <token>`.

Browser clients work because of a CORS middleware (`server/src/cors.rs`): the
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
| `file` | Not empty, at most 500 MiB. **Every audio file is accepted** — the extension does not have to be one the server knows. What the bytes prove decides: content that is recognizably not audio (text, an image, a PDF, an archive, an executable) is refused under any name, and a content type the server can read wins over the extension. When the bytes are plain binary, the extension names the type: `mp3`, `m4a`, `ogg`/`opus`, `wav`, `flac`, `aac` map to the documented types, any other extension is served as `audio/<extension>` (e.g. `song.aiff` → `audio/aiff`). A file without an extension is refused only when its bytes say nothing. |
| name | Base name only, no control characters, at most 200 characters. An MP3 whose tags name a title (`TIT2`) uses that instead, so a file is titled by what it says about itself; the name is the fallback. The file itself is stored under a generated name (16 random bytes as hex + the extension), so no client name can escape the library folder and no upload overwrites another song. |

**Responses**

| Status | When | Example body |
|---|---|---|
| `201 Created` | File saved in the library and the row inserted | `{"id": 4, "uploaded_by": "lukas", "title": "Neutrone (Remix)", "artist": "Kraftwerk", "duration_ms": 261000, "stored_name": "18cfd7db41d243d98cc87c4ab33dded6.mp3", "size": 4237, "content_type": "audio/mpeg", "uploaded_at": 1793974311}` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token | `{"error": "session is not valid or expired"}` |
| `400 Bad Request` | Not `multipart/form-data`, no file, the field is not named `file`, an empty file, a name with no usable characters, a file without an extension whose bytes say nothing, or content that is not audio | `{"error": "the uploaded file is not audio, its content reads as application/zip"}` |
| `413 Request Entity Too Large` | Upload larger than 500 MiB | `{"error": "upload is larger than 500 MiB"}` |
| `429 Too Many Requests` | Upload rate limit reached (3 requests per IP, refilling 1 token every 30 s — its own bucket). Includes a `Retry-After` header (seconds until the next token, at most the 30 s refill window). | `{"error": "too many uploads from this address, try again later"}` |
| `500 Internal Server Error` | Writing the file or inserting the row failed | `{"error": "could not save the file"}` |

**Notes**

- Authentication is checked before the body is read, so an anonymous caller
  cannot make the server read 500 MiB it would throw away.
- The file is written before the row is inserted; if the insert fails, the file
  is removed again, so a library entry never points at a missing file.
- `stored_name` is what the file is called inside the library folder; `GET /api/music`
  sends it back, and `GET /api/music/{id}` names it in `Content-Disposition`.
- `artist` and `duration_ms` are what the file says about itself (`server/src/metadata.rs`):
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

  A `saphire.db` created before these columns get them: `ensure_columns` in
  `server/src/music.rs` reads `PRAGMA table_info(track)` and adds the missing ones, so an
  old row keeps reading as an untagged file instead of failing.

### `GET /api/music`

Lists the shared library: every song as the full track row, ordered by `id`. Only a
logged-in user may read it, with the same two 401 messages as `GET /api/session`.
An empty library answers `[]`, never `null`.

```
GET /api/music
Authorization: Bearer <token>
```

**Response shape**

```json
[
  {
    "id": 4, "uploaded_by": "lukas", "title": "lied.wav", "artist": "",
    "duration_ms": 0, "stored_name": "18cfd7db41d243d98cc87c4ab33dded6.wav",
    "size": 32, "content_type": "audio/wav", "uploaded_at": 1793974311
  }
]
```

Every field `POST /api/music/upload` reported is in the answer, including `uploaded_by`
and `stored_name`. A row without tags reads as an empty artist and a length of `0`,
which a client shows as a dash rather than a guess.

**Responses**

| Status | When | Example body |
|---|---|---|
| `200 OK` | Library listed, ordered by `id` | `[{ "id": 4, "uploaded_by": "lukas", "title": "lied.wav", "artist": "", "duration_ms": 0, "stored_name": "18cfd7db…wav", "size": 32, "content_type": "audio/wav", "uploaded_at": 1793974311 }]` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token (the row is dropped), or the token's user no longer exists | `{"error": "session is not valid or expired"}` |
| `429 Too Many Requests` | Rate limit reached (10 requests per IP, refilling 1 token every 12 s — its own bucket). Includes a `Retry-After` header. | `{"error": "too many requests from this address, try again later"}` |
| `500 Internal Server Error` | Database failure while reading the library | `{"error": "could not list the library"}` |
| `500 Internal Server Error` | Database failure while checking the token, with the same answers as `GET /api/session` | `{"error": "could not load session"}` or `{"error": "could not load user"}` |

No pagination yet: every row is returned in one answer.

### `GET /api/music/{id}`

Sends the file of one song. Only a logged-in user may read it, with the same two 401
messages as `GET /api/session`. The file is **streamed in pieces**: the server reads
32 KiB at a time (`CHUNK_BYTES` in `server/src/music.rs`) and writes each piece as it
reads it, so a player gets the start of a song before the rest of the file is read, and
a large song is never held in memory as a whole.

```
GET /api/music/{id}
Authorization: Bearer <token>
```

**Headers on a successful answer**

| Header | Value |
|---|---|
| `Content-Type` | the type stored for that song (`audio/mpeg`, `audio/wav`, …) |
| `Content-Length` | the bytes that are actually sent — the whole file, or the requested range |
| `Accept-Ranges` | `bytes` |
| `Content-Disposition` | `inline; filename="<stored_name>"`, the name the file has inside the library folder |
| `Content-Range` | `bytes <from>-<to>/<size>`, on a `206` only |
| `X-Content-Type-Options` | `nosniff`, like every other answer from this server |

`Content-Length` is known because the file is in the library, so the transfer is not
chunk-encoded — but the bytes still leave piece by piece. One `Range` is served, not a
list of ranges, because that is what an audio player sends; a list (`bytes=0-10,20-30`) is
refused with `416` rather than answered as several parts. An open end (`bytes=900-`)
means the rest of the file, and a suffix (`bytes=-500`) means the last 500 bytes. A start
past the last byte, a suffix larger than the file, or an end past the last byte is refused
rather than clamped — that is a deliberate difference from RFC 9110, which would serve such
a range as the whole file, so a player that sends `bytes=0-2147483647` gets `416` here. A
range that ends at the last byte is the whole file and is served as `206`. The JSON error
shape is used for everything decided before the first byte; the `416` is written as plain
text, because that answer is about the transport rather than the API.

**Responses**

| Status | When | Example body |
|---|---|---|
| `200 OK` | The whole file, in 32 KiB pieces | the file bytes |
| `206 Partial Content` | A `Range` that is inside the file | the requested part, in the same 32 KiB pieces |
| `400 Bad Request` | `id` is not a plain positive number (`-1`, `0`, `0004`, `+4`, `abc`) | `{"error": "the song id must be a positive number"}` |
| `400 Bad Request` | Digits, but too large to be an id | `{"error": "the song id is too large"}` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token | `{"error": "session is not valid or expired"}` |
| `404 Not Found` | No row with that id | `{"error": "song is not in the library"}` |
| `404 Not Found` | The row exists but its file is gone (a broken library) | `{"error": "the file for this song is not in the library folder"}` |
| `416 Requested Range Not Satisfiable` | A `Range` that cannot be read as bytes (`bytes=abc`), a list of ranges, or one outside the file | plain text `invalid range`, with `Content-Range: bytes */<size>` — the only answer here that is not the JSON shape |
| `429 Too Many Requests` | Rate limit reached (10 requests per IP, refilling 1 token every 10 s — its own bucket). Includes a `Retry-After` header. | `{"error": "too many requests from this address, try again later"}` |
| `500 Internal Server Error` | Database failure, or the file could not be opened | `{"error": "could not load the song"}` or `{"error": "could not read the file"}` |
| `500 Internal Server Error` | Database failure while checking the token, with the same answers as `GET /api/session` | `{"error": "could not load session"}` or `{"error": "could not load user"}` |

**Notes**

- Every error above is answered **before the first byte**. Once `200` and the audio
  content type are sent, the status is fixed: a read failure that happens mid-stream
  cannot become a JSON error, it only ends the body. A client must treat a body that
  stops early as a failed read, not as a complete song. In practice that looks like
  fewer bytes than `Content-Length` and a connection that is not reused — with
  `net/http` the client sees `unexpected EOF` while reading.
- The client's `Accept` header does not matter here — the content type comes from the
  record written at upload time.

---

### Playlists

A playlist belongs to the user who created it — unlike the library, which is shared.
Every playlist endpoint reads only the caller's own playlists, so a playlist of another
user is answered as **not in your playlists** rather than as forbidden: from the
caller's view it does not exist.

Positions inside a playlist are 1-based and always contiguous: adding puts a song at the
end, and removing a song renumbers the songs after it, so a client can address a slot
without knowing the history. A song can be in a playlist more than once, at different
positions, because a playlist is an order, not a set.

Name rules: control characters are dropped, at most 100 characters (characters, not
bytes), and a name past that is refused rather than cut — a playlist keeps the name it was
given, the same way the 200 songs cap is a refusal and not a silent drop. A name is not
unique. A rate-limited answer here uses the playlist bucket (10 requests per IP, one token
every 12 s), separate from the library and queue buckets, so building a playlist cannot
stop playback.

#### `POST /api/playlists`

```
POST /api/playlists
Authorization: Bearer <token>
```

Body: one JSON object with `name`, at most 4 KiB, `DisallowUnknownFields`. Trailing content
after the object is a separate 400 with `{"error": "body must contain exactly one JSON
object"}` — the same rule and the same message the register endpoint gives, and every
playlist and queue body is read this way.

**Response shape**

```json
{ "id": 1, "name": "Favoriten", "created_at": 1794180269, "song_count": 0 }
```

| Status | When | Example body |
|---|---|---|
| `201 Created` | Playlist created | the record above |
| `400 Bad Request` | Body is not one JSON object with `name` | `{"error": "body must be one JSON object with \"name\""}` |
| `400 Bad Request` | Name is empty, or only control characters | `{"error": "the playlist needs a name"}` |
| `400 Bad Request` | Name is past 100 characters; nothing is stored | `{"error": "a playlist name is at most 100 characters"}` |
| `401 Unauthorized` | Missing `Authorization: Bearer` header | `{"error": "authorization header with a Bearer token is missing"}` |
| `401 Unauthorized` | Unknown or expired token | `{"error": "session is not valid or expired"}` |
| `429 Too Many Requests` | Playlist bucket reached. Includes `Retry-After`. | `{"error": "too many requests from this address, try again later"}` |
| `500 Internal Server Error` | Database failure, or a failure while checking the token | `{"error": "the playlist could not be read"}`, or the two `GET /api/session` messages |

#### `GET /api/playlists`

The caller's playlists, ordered by `id`. An empty list answers `[]`, never `null`.
`song_count` is a count; the songs come from `GET /api/playlists/{id}`, so a client that
shows playlists does not get every song of every playlist in one answer.

```
GET /api/playlists
Authorization: Bearer <token>
```

**Response shape**

```json
[
  { "id": 1, "name": "Favoriten", "created_at": 1794180269, "song_count": 2 }
]
```

Statuses are as in `POST /api/playlists`, with `200 OK` for the list.

#### `GET /api/playlists/{id}`

One playlist with its songs in position order. The title comes from the library row: a
playlist stores references, not copies. An empty playlist answers `[]` for `songs`.

```
GET /api/playlists/{id}
Authorization: Bearer <token>
```

**Response shape**

```json
{
  "id": 1,
  "name": "Favoriten",
  "created_at": 1794180269,
  "song_count": 2,
  "songs": [
    { "position": 1, "track_id": 8, "title": "Technogal.mp3" },
    { "position": 2, "track_id": 4, "title": "lied.wav" }
  ]
}
```

| Status | When | Example body |
|---|---|---|
| `200 OK` | The caller's playlist with its songs | the shape above |
| `400 Bad Request` | `{id}` is not a plain positive number (`-1`, `0`, `0004`, `+4`, `abc`) | `{"error": "the playlist id must be a positive number"}` |
| `400 Bad Request` | Digits, but too large to be an id | `{"error": "the playlist id is too large"}` |
| `401 Unauthorized` | Same two messages as `GET /api/session` | |
| `404 Not Found` | No playlist with that id, or it belongs to another user | `{"error": "playlist is not in your playlists"}` |
| `429` / `500` | As in `POST /api/playlists` | |

#### `POST /api/playlists/{id}/songs`

Adds one library song at the end and answers the position it got. The song must be in
the library, and the playlist must be the caller's. Counting and inserting happen in one
transaction on one connection, so two callers cannot be given the same position: a second
write waits for the first (`busy_timeout`) instead of answering a server error.

```
POST /api/playlists/{id}/songs
Authorization: Bearer <token>
```

Body: one JSON object with `track_id` (a library id, the same number `GET /api/music`
shows).

**Response shape** — `201 Created` with `{"position": 3, "track_id": 8, "title": "Technogal.mp3"}`.

| Status | When | Example body |
|---|---|---|
| `201 Created` | Song added at the end | the shape above |
| `400 Bad Request` | Body is not one JSON object with `track_id` | `{"error": "body must be one JSON object with \"track_id\""}` |
| `400 Bad Request` | `track_id` is not a positive number | `{"error": "track_id must be a positive number"}` |
| `400 Bad Request` | The playlist already holds 200 songs; nothing is dropped | `{"error": "a playlist holds at most 200 songs"}` |
| `401` | Same two messages as `GET /api/session` | |
| `404 Not Found` | Playlist is not yours | `{"error": "playlist is not in your playlists"}` |
| `404 Not Found` | The song is not in the library | `{"error": "song is not in the library"}` |
| `429` / `500` | As in `POST /api/playlists` | |

#### `DELETE /api/playlists/{id}/songs/{position}`

Removes one slot and renumbers the songs after it, so the positions stay 1..n. A `204`
has no body and sets no `Content-Type`.

| Status | When | Body |
|---|---|---|
| `204 No Content` | The slot was removed | none |
| `400 Bad Request` | `{position}` is not a plain positive number | `{"error": "the position must be a positive number"}` |
| `400 Bad Request` | Digits, but too large to be a position (past int64) | `{"error": "the position is too large"}` |
| `401` | Same two messages as `GET /api/session` | JSON |
| `404 Not Found` | Playlist is not yours | `{"error": "playlist is not in your playlists"}` |
| `404 Not Found` | Nothing at that position; the answer names it | `{"error": "no song at position 3 in this playlist"}` |
| `429` / `500` | As in `POST /api/playlists` | JSON |

#### `DELETE /api/playlists/{id}`

Deletes the playlist and its song rows. **The songs stay in the shared library** — a
playlist is a list of references, not a copy of the file. `204 No Content`, no body. The
other statuses are as above.

---

### Queue

A queue is one user's ordered list of songs. It stores only which songs and in which
order — nothing about what filled it, so any source produces the same shape. That is the
point: filling it from a playlist is one source, and a plain queue feature later is
another source, not a different queue.

The queue is per user, positions are 1-based and contiguous like inside a playlist, a
song may appear twice, and one queue holds at most 200 entries so one answer stays
bounded. What is *currently playing* is not stored here: playback position is device
state, and the server only knows the order.

The queue has its own rate-limit bucket (10 requests per IP, one token every 12 s),
separate from the playlists and the library, so a player reading its queue cannot stop a
client from building a playlist.

**Sources** — `POST /api/queue` takes `source` and, for a source that names something,
`source_id`:

| Source | What it fills the queue with | Needs `source_id` |
|---|---|---|
| `playlist` | The songs of one playlist, in the playlist's position order | yes, and the playlist must be yours |
| `library` | Every song in the shared library, ordered by `id` | no — sending one is refused |
| `track` | One song by itself | yes |

Adding a source later (search results, "songs you uploaded") is one branch in
`queueSongIDs`; nothing else about a queue changes.

#### `POST /api/queue`

Replaces the queue with the songs of one source. Filling is not adding: starting a second
playlist must not keep the songs of the first.

```
POST /api/queue
Authorization: Bearer <token>
```

Body: one JSON object with `source` (and `source_id` where the source needs it).

**Response shape** — `200 OK` with the queue as it now is:

```json
[
  { "position": 1, "track_id": 8, "title": "Technogal.mp3" },
  { "position": 2, "track_id": 4, "title": "lied.wav" }
]
```

| Status | When | Example body |
|---|---|---|
| `200 OK` | Queue replaced. A source with no songs (`playlist` with none, an empty library) fills an empty queue, which is `[]` and is not error. | the shape above |
| `400 Bad Request` | Body is not one JSON object with `source` | `{"error": "body must be one JSON object with \"source\""}` |
| `400 Bad Request` | `source` is not `playlist`, `library` or `track` | `{"error": "source must be \"playlist\", \"library\" or \"track\""}` |
| `400 Bad Request` | `source_id` sent for `library` — sent is sent, so `0` counts as sent | `{"error": "source_id is not used for the whole library"}` |
| `400 Bad Request` | `source_id` is missing or not a positive number for `playlist` or `track` | `{"error": "source_id must be a positive number"}` |
| `400 Bad Request` | The source has more songs than the queue holds; the queue is not left half filled, because the refusal happens before anything is deleted | `{"error": "the queue holds at most 200 songs"}` |
| `401` | Same two messages as `GET /api/session` | |
| `404 Not Found` | The playlist named by `source_id` is not yours | `{"error": "playlist is not in your playlists"}` |
| `404 Not Found` | The song named by `source_id` is not in the library. A `track` source names exactly one song, so it cannot be an empty queue here. | `{"error": "song is not in the library"}` |
| `429` / `500` | As in `POST /api/playlists`, with the queue messages | |

#### `GET /api/queue`

The caller's queue in position order. An empty queue answers `[]`, never `null`. `200 OK`
with the shape above; `401`, `429` and `500` as in `POST /api/queue`.

#### `POST /api/queue/songs`

Adds one song at the end without a source — the plain queue feature. `201 Created` with
`{"position": 3, "track_id": 8, "title": "Technogal.mp3"}`. `track_id` must be in the
library; the limit is a real limit, not a silent drop. Statuses as in
`POST /api/playlists/{id}/songs`.

#### `DELETE /api/queue/{position}`

Removes one slot and renumbers the rest. `204 No Content`, no body. An empty slot names
the position: `{"error": "no song at position 3 in this queue"}`. A position that is digits
but past int64 is `400` with `{"error": "the position is too large"}` — the same rule as an
id. Other statuses as above.

#### `DELETE /api/queue`

Empties the queue. `204 No Content`, no body. The songs stay in the library.

**What a client has to know**

- The server never says which song a device is playing. A client that plays keeps its own
  position in the list; the server only keeps the order. Two devices reading the same
  queue see the same list, not the same playback.
- The audio for an entry comes from `GET /api/music/{track_id}`. A queue entry is a
  reference, so the title and the file can change under it.

---

## Upcoming

Planned, in rough order:

- `POST /api/logout` — delete the session row for the presented token and
  answer `204 No Content`. Same `Authorization: Bearer` rule as
  `GET /api/session`; a client that keeps the token after logout should be
  refused with the same 401 message as an expired session.
- Reordering inside a playlist or a queue — move a song to another position
  (`PUT /api/playlists/{id}/songs/{position}` with a `target`), which is what a client
  that lets a user drag a song needs. Shuffle and repeat are not here: they are a device
  choice, not something the server can answer.
- `PATCH /api/playlists/{id}` — rename a playlist. Creating and deleting are covered.
- Search inside the library — `GET /api/music?q=<term>`, the same rows as the list but only
  the ones whose title contains `q`, case-insensitive, ordered by title. `q` must not be
  empty. This is what a page that searches needs: while the list has no search, the client
  reads the whole library and filters what it got.
- Pagination for `GET /api/music` and `GET /api/playlists`, once one answer is too much.
  The current caps (200 songs per playlist, 200 entries per queue) keep one answer
  bounded until then.
- The equalizer has no API yet. Playlists and the queue do — see **Implemented** above.

---

## Development frontend

`server/static/` holds a plain HTML page for calling these endpoints from a browser
while they are being built. `src/main.rs` serves it for `GET /static/` through
`src/staticfiles.rs`, from the folder relative to the directory the server is started from
(`just run` inside `server/`); nothing is compiled into the binary, so editing a
file and reloading the page is enough.

It is mounted under its own prefix on purpose. A pattern for `/` is a wildcard, so it
would also answer `/api/*` for a method no endpoint serves, and a wrong-method request
would get the page's plain text 404 instead of the `405` the endpoints above document.
The root itself is the exact root pattern (`GET /{$}`), so it cannot take an API path
over; it only forwards a browser to the page.

These answers are not part of the API: they are `text/html`, `text/css` and
`text/javascript` (with `X-Content-Type-Options: nosniff`, like every other answer
from this server), and a missing file is the plain text `404 page not found` rather
than the JSON error shape:

| Route | Status | What it answers |
|---|---|---|
| `GET /` | `301 Moved Permanently` | `Location: /static/`, so a tab opened at the root reaches the page |
| `GET /static/` | `200 OK` | `static/index.html` |
| `GET /static/index.html` | `301 Moved Permanently` | `Location: ./`, because the page folder treats its index file as the folder itself — the page has one address |
| `GET /static/style.css`, `GET /static/app.js` | `200 OK` | the files the page links |
| `GET /static/<anything else>` | `404 Not Found` | plain text `404 page not found` |
| `GET /<a path no endpoint defines>` | `404 Not Found` | the same plain text `404 page not found` — a path that is not an endpoint cannot fail an endpoint, so the JSON error shape does not apply here |
| `GET /static/../<name>` | `307 Temporary Redirect` | the path is cleaned before a handler is chosen, so a `..` element is resolved as part of the path; following the `Location` still answers the plain text `404` above, because nothing above the page folder can be served |
| `POST /static/` | `405 Method Not Allowed` | only GET serves the page |

The page sends exactly what is typed and shows what the server answered: the status
code, the elapsed time, `Retry-After` when a rate limit answers 429, and the same
request written as `curl`. It keeps the session token in `sessionStorage` for the
current tab and shows it from there — the raw token is still only ever returned by
`POST /api/login`, and the database still stores only its hash. On load the page calls
`GET /api/session` with the stored token, so the 401 path is visible
without logging in again.

There is one card per implemented endpoint group: register, login, session check,
upload, list, stream, playlists, queue. For the stream the log shows which chunks
arrived and when, because that is the point of that endpoint; for the playlist and queue
cards the responses are JSON, so they are shown as they come.
