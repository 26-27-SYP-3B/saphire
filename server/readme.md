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
