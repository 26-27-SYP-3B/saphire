use std::path::Path;
use std::sync::Arc;

use tokio::sync::Mutex;
use tokio_rusqlite::{rusqlite, Connection};

use crate::{music, playlist, queue, respond::Failure};

pub type Db = Arc<Mutex<Connection>>;

/// Domain code runs on one connection on purpose. SQLite lets one writer at a time, and a
/// ":memory:" database is a different database on every connection. With one connection the
/// count and the insert that belong to it are one uninterrupted piece of work, so two
/// callers cannot be handed the same position.
///
/// The `Arc<Mutex<_>>` is what makes the shared state `Sync`: a bare `Connection` handle is
/// not, because the closure it sends to the connection thread takes `&mut self`. `call` hands
/// that connection to a function written against `rusqlite::Connection`, so the same domain
/// function can also run inside a transaction.
pub async fn call<F, R>(db: &Db, f: F) -> Result<R, Failure>
where
    F: FnOnce(&mut rusqlite::Connection) -> Result<R, Failure> + Send + 'static,
    R: Send + 'static,
{
    let guard = db.lock().await;

    match guard.call(f).await {
        Ok(value) => Ok(value),
        Err(tokio_rusqlite::Error::Error(failure)) => Err(failure),
        // The connection thread is gone; only a server error can be answered from here.
        Err(_) => Err(Failure::Db("connection closed".to_string())),
    }
}

/// Turns what the driver reported into the answer the endpoint can give. The only UNIQUE the
/// server depends on is the username, so a constraint failure is treated as that one — the same
/// way the Go version reads the message instead of the driver's code, because the driver reports
/// every constraint violation as one code.
pub fn failure(error: rusqlite::Error) -> Failure {
    match error {
        rusqlite::Error::QueryReturnedNoRows => Failure::NoRows,
        _ if error.to_string().contains("UNIQUE constraint failed") => Failure::Unique,
        _ => Failure::Db(error.to_string()),
    }
}

pub fn db_path() -> String {
    match std::env::var("SAPHIRE_DB_PATH") {
        Ok(path) if !path.is_empty() => path,
        _ => "saphire.db".to_string(),
    }
}

pub async fn open_db_with(path: &str) -> Result<Db, Failure> {
    let connection = Connection::open(Path::new(path))
        .await
        .map_err(|error| Failure::Db(error.to_string()))?;
    let db: Db = Arc::new(Mutex::new(connection));

    call(&db, |conn| {
        // Two writes that meet would otherwise answer the second with a server error instead
        // of the position it asked for; waiting briefly is what keeps the answer honest.
        conn.pragma_update(None, "busy_timeout", 5000)
            .map_err(failure)?;

        // Note: the schema changed (name/email -> username/password_hash). An old saphire.db
        // is not migrated; `CREATE TABLE IF NOT EXISTS` keeps it as it is, so delete it for a
        // fresh start.
        ensure_user_table(conn).map_err(failure)?;
        ensure_session_table(conn).map_err(failure)?;
        // The library tables live in their own domain files. The same for playlists and the
        // queue.
        music::ensure_table(conn).map_err(failure)?;
        playlist::ensure_tables(conn).map_err(failure)?;
        queue::ensure_table(conn).map_err(failure)?;
        Ok(())
    })
    .await?;

    Ok(db)
}

pub async fn open_db() -> Result<Db, Failure> {
    open_db_with(&db_path()).await
}

fn ensure_user_table(conn: &mut rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS user (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            username TEXT NOT NULL UNIQUE,
            password_hash TEXT NOT NULL
        )",
        (),
    )?;
    Ok(())
}

fn ensure_session_table(conn: &mut rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute(
        "CREATE TABLE IF NOT EXISTS session (
            token_hash TEXT PRIMARY KEY,
            user_id INTEGER NOT NULL REFERENCES user(id),
            created_at INTEGER NOT NULL,
            expires_at INTEGER NOT NULL
        )",
        (),
    )?;
    Ok(())
}
