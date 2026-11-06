# Saphire Server API

Base URL: `http://localhost:8080` (port configurable via `PORT` in `.env`).

All responses are JSON with `Content-Type: application/json` and
`X-Content-Type-Options: nosniff`. Errors use a single shape:

```json
{ "error": "human readable description of what went wrong" }
```

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

## Planned endpoints

Nothing beyond the endpoints above is implemented. A login endpoint would verify
the password with `bcrypt.CompareHashAndPassword` (constant time by design).
