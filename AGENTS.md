# AGENTS.md

Instructions for AI coding agents working in this repository.

## Project layout

```
saphire/
├── server/    # Rust HTTP server (crate saphire-server) — work here for API tasks
├── client/    # Flutter app (saphire_client)
├── dokumente/ # project paperwork, do not edit
└── api-docs.md # the API documentation — this is the one docs file
```

## Commands (from `server/`)

```bash
just build     # cargo build
just run       # cargo run
just test      # cargo test
just check     # cargo clippy --all-targets -- -D warnings
just clean     # rm -rf target
```

Use `just check` and `just test` before declaring work done. The server is one crate with one
module per domain area in `src/` (`user.rs`, `register.rs`, …); `src/main.rs` is the thin entry
point so the integration tests in `tests/` can use the library. Keep it that way unless asked to
restructure.

## Conventions

- HTTP with axum method patterns (`POST /api/register`); SQLite via `tokio-rusqlite` with the
  `bundled` feature, so no system SQLite is needed. One connection, behind a lock.
- A handler future must be `Send`, so a handler may not hold a borrow of the request across an
  `.await` — read a header into an owned value first. Shared state must be `Sync`, which is why
  the connection is an `Arc<Mutex<_>>` and domain functions take `&rusqlite::Connection` so the
  same function can also run inside a transaction.
- Environment config comes from `.env` (loaded with dotenvy); document new variables in `.env.template`.
- All responses go through the helpers in `src/respond.rs`. One file per domain area (e.g. `src/user.rs`, `src/register.rs`).
- Comments explain *why*, not *what* — e.g. why the password length cap is 72.
- Keep `api-docs.md` (in the project root) in sync: any endpoint change must update its entry, including status codes and error messages, and move planned endpoints between its **Upcoming** and **Implemented** sections.

## Security rules — do not weaken these

These are deliberate decisions, not accidents. Change them only with an explicit request.

1. Users have **only username + password**. Do not add email or other fields.
2. Passwords are stored as **bcrypt hashes (cost 12)**, never as plain text, never logged, never serialized (serde `skip` on `User.password_hash`).
3. Password max length is **72 bytes** because bcrypt truncates longer input silently — reject, don't truncate.
4. Usernames are **normalized to lowercase** before validation and storage, and uniqueness is enforced by the DB `UNIQUE` constraint, not by an application-level check.
5. Only **parameterized queries** — never build SQL by concatenating user input.
6. The hash is computed **before** the insert so response timing does not reveal whether a username exists. Keep this order.
7. The registration endpoint is **rate-limited per IP** (token bucket, 5 burst / 1 refill per 12 s) and enforces a 4 KiB body limit with strict JSON parsing (`DisallowUnknownFields`).
8. Error responses state what happened and the fix; they never leak internal details (no stack traces, no driver error strings).
9. Session tokens come from the OS random source (`getrandom`, 32 bytes), the database stores only their **SHA-256 hash** as the primary key, sessions have a **24 h TTL** and expired rows are dropped on lookup. Keep the raw token out of the database.
10. A failed login answers the **same generic 401** whether the user is unknown or the password is wrong, and the unknown-user path compares against a dummy hash so timing does not reveal whether a username exists. Login, registration and session checks use **separate** rate-limit buckets.

## Testing

Server tests exist in `server/tests/`, one file per area (`just test`). Keep them green and
extend them for new behavior; `just check` must stay clean. Additionally verify with `curl` — the
responses in `api-docs.md` are the expected behavior, including status codes and headers
(`Retry-After`, `X-Content-Type-Options`). A rate-limit test uses a long refill window so it
measures the limit instead of how fast this machine hashes a password.

## Before pushing — independent review

Before pushing newly written code, delegate a **sub-agent** review of just the
diff you wrote. The sub-agent has no memory of this chat, so give it only the
changed files and this brief: look for **logical errors and programmatical
bugs** — off-by-one and length limits that count bytes but claim characters,
wrong status codes, errors that are swallowed or mislabelled, validation that
disagrees with `api-docs.md`, unbounded maps or leaked resources, and anything
that breaks the *Security rules* invariants (timing parity, parameterized
queries, hash-before-insert order). It must not restate the code; it returns
concrete findings with `file:line` and the fix.

Reconcile its findings against `just check` and `just test` before pushing, and add
a test for any real bug it confirms. If two checks disagree, verify against the
code yourself — do not average them.

## Gotchas

- An existing `saphire.db` uses the old `name`/`email` schema. `CREATE TABLE IF NOT EXISTS` will not migrate it; delete the file for a fresh start.
- The rate limiter state is in memory and resets on restart.
- Browser clients only work through the CORS middleware in `src/cors.rs`; without the reflected Origin the browser blocks every JSON POST. On devices, `127.0.0.1` is the device itself — `API_BASE_URL` must point at the development machine (Android emulator: `10.0.2.2`).
- The project is a school project (3BHIF): prefer simple, readable code over frameworks.
