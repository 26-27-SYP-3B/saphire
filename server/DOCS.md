# Saphire Server API

Base URL: `http://localhost:8080` (port configurable via `PORT` in `.env`).

All responses are JSON with `Content-Type: application/json` and
`X-Content-Type-Options: nosniff`. Errors use a single shape:

```json
{ "error": "human readable description of what went wrong" }
```

Authenticated requests carry the session token in
`Authorization: Bearer <token>`.

---

## `POST /api/register`

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
| `password` | 8–72 characters, no control characters. 72 is the bcrypt limit — longer input is rejected instead of silently truncated. Stored only as a bcrypt hash (cost 12), never returned or logged. |

**Responses**

| Status | When | Example body |
|---|---|---|
| `201 Created` | User registered | `{"id": 1, "username": "lukas"}` |
| `400 Bad Request` | Malformed JSON, unknown fields, oversized body, or a username/password that fails the rules | `{"error": "password must be at least 8 characters"}` |
| `409 Conflict` | Username already taken | `{"error": "username is not available"}` |
| `429 Too Many Requests` | Rate limit reached (5 requests per IP, refilling 1 token every 12 s). Includes `Retry-After: 60` header. | `{"error": "too many registrations from this address, try again later"}` |
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

---

## `POST /api/login`

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
| `429 Too Many Requests` | Login rate limit reached. Includes `Retry-After: 60` header. | `{"error": "too many logins from this address, try again later"}` |
| `500 Internal Server Error` | Database failure | `{"error": "could not load user"}` |

**Notes**

- The token is 32 random bytes from `crypto/rand` as 64 hex characters. It is
  only shown once, in this response; the database stores just its SHA-256 hash,
  so a leaked database does not hand out usable sessions.
- Sessions expire 24 hours after login (`sessionTTL`). Expired rows are dropped
  on the next lookup.
- Unknown users are answered with the same 401 after a comparison against a
  dummy hash, so the response time does not reveal whether a username exists.

---

## `GET /api/session`

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
| `401 Unauthorized` | Unknown or expired token (the row is dropped) | `{"error": "session is not valid or expired"}` |
| `429 Too Many Requests` | Session rate limit reached | `{"error": "too many requests from this address, try again later"}` |

**Database schema for sessions**

```sql
CREATE TABLE IF NOT EXISTS session (
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES user(id),
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
)
```

---

## Planned endpoints

Nothing beyond the endpoints above is implemented. A logout endpoint would
delete the session row for the presented token.
