use std::sync::Arc;

use crate::db::Db;
use crate::ratelimit::RateLimiter;

/// What a handler needs. One limiter per endpoint group, so a client that polls the library
/// cannot starve playback and a player reading its queue cannot stop the playlists.
#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub limiter: Arc<RateLimiter>,
    pub library: String,
}

pub fn state(db: &Db, limiter: Arc<RateLimiter>, library: &str) -> AppState {
    AppState {
        db: db.clone(),
        limiter,
        library: library.to_string(),
    }
}
