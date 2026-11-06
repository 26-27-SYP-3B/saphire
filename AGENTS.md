# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project layout

```
saphire/
├── server/    # Go HTTP server (module saphire-server) — work here for API tasks
├── client/    # Flutter app (saphire_client)
└── dokumente/ # project paperwork, do not edit
```

## Commands (from `server/`)

```bash
just build     # go build -o build/saphire-server .
just run       # go run .
just test      # go test ./...
just clean     # rm -rf build
go vet ./...   # must stay clean
```

Use `go vet` and `go test` before declaring work done. The whole server is a single `package main`; keep it that way unless asked to restructure.

## Conventions

- Go standard library only for HTTP (`net/http` with method patterns like `POST /api/register`); SQLite via `modernc.org/sqlite` (pure Go driver, no CGO).
- Environment config comes from `.env` (loaded with godotenv); document new variables in `.env.template`.
- All responses go through the `writeJSON`/`writeError` helpers in `main.go`. One file per domain area (e.g. `user.go`, `register.go`).
- Comments explain *why*, not *what* — e.g. why the password length cap is 72.
- Keep `DOCS.md` in sync: any endpoint change must update its entry, including status codes and error messages.

## Security rules — do not weaken these

These are deliberate decisions, not accidents. Change them only with an explicit request.

1. Users have **only username + password**. Do not add email or other fields.
2. Passwords are stored as **bcrypt hashes (cost 12)**, never as plain text, never logged, never serialized (`json:"-"` on `User.PasswordHash`).
3. Password max length is **72 bytes** because bcrypt truncates longer input silently — reject, don't truncate.
4. Usernames are **normalized to lowercase** before validation and storage, and uniqueness is enforced by the DB `UNIQUE` constraint, not by an application-level check.
5. Only **parameterized queries** — never build SQL by concatenating user input.
6. The hash is computed **before** the insert so response timing does not reveal whether a username exists. Keep this order.
7. The registration endpoint is **rate-limited per IP** (token bucket, 5 burst / 1 refill per 12 s) and enforces a 4 KiB body limit with strict JSON parsing (`DisallowUnknownFields`).
8. Error responses state what happened and the fix; they never leak internal details (no stack traces, no driver error strings).
9. Session tokens come from `crypto/rand` (32 bytes), the database stores only their **SHA-256 hash** as the primary key, sessions have a **24 h TTL** and expired rows are dropped on lookup. Keep the raw token out of the database.
10. A failed login answers the **same generic 401** whether the user is unknown or the password is wrong, and the unknown-user path compares against a dummy hash so timing does not reveal whether a username exists. Login, registration and session checks use **separate** rate-limit buckets.

## Testing

Server tests exist in `server/` (`just test`). Keep them green and extend them for
new behavior. Additionally verify with `curl` — the responses in `DOCS.md` are the
expected behavior, including status codes and headers (`Retry-After`,
`X-Content-Type-Options`).

## Gotchas

- An existing `saphire.db` uses the old `name`/`email` schema. `CREATE TABLE IF NOT EXISTS` will not migrate it; delete the file for a fresh start.
- The rate limiter state is in memory and resets on restart.
- The project is a school project (3BHIF): prefer simple, readable code over frameworks.
