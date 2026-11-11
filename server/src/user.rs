use serde::{Deserialize, Serialize};
use tokio_rusqlite::rusqlite;

use crate::{db, respond::Failure};

/// A row of the "user" table. Only username and password are stored; the password is kept
/// as a bcrypt hash and never serialized, so an answer cannot hand it out.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct User {
    pub id: i64,
    pub username: String,
    #[serde(skip)]
    pub password_hash: String,
}

pub fn ensure_table(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
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

/// Finds a user by its normalized username. Always parameterized.
pub fn get_by_username(conn: &rusqlite::Connection, username: &str) -> Result<User, Failure> {
    conn.query_row(
        "SELECT id, username, password_hash FROM user WHERE username = ?1",
        (username,),
        |row| {
            Ok(User {
                id: row.get(0)?,
                username: row.get(1)?,
                password_hash: row.get(2)?,
            })
        },
    )
    .map_err(db::failure)
}

/// Loads a user for a session lookup.
pub fn get_by_id(conn: &rusqlite::Connection, id: i64) -> Result<User, Failure> {
    conn.query_row(
        "SELECT id, username, password_hash FROM user WHERE id = ?1",
        (id,),
        |row| {
            Ok(User {
                id: row.get(0)?,
                username: row.get(1)?,
                password_hash: row.get(2)?,
            })
        },
    )
    .map_err(db::failure)
}

/// Saves the user and fills in its id. Uniqueness is enforced by the UNIQUE constraint, not
/// by a check here, so a race answers as the constraint rather than as a duplicate the
/// server happened to notice.
pub fn insert(conn: &rusqlite::Connection, user: &mut User) -> Result<(), Failure> {
    conn.execute(
        "INSERT INTO user (username, password_hash) VALUES (?1, ?2)",
        (&user.username, &user.password_hash),
    )
    .map_err(db::failure)?;

    user.id = conn.last_insert_rowid();
    Ok(())
}
