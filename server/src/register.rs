use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::post;
use axum::Router;
use serde::Deserialize;

use crate::{db, jsonbody, ratelimit, respond, sanitize, state::AppState, user};

pub const MIN_USERNAME_LEN: usize = 3;
pub const MAX_USERNAME_LEN: usize = 32;
pub const MIN_PASSWORD_LEN: usize = 8;
/// 72 is the bcrypt limit. Longer input is truncated silently by the hash, so it is refused
/// here instead of stored as a shorter password than the one that was typed. The count is
/// bytes, because that is what bcrypt truncates at.
pub const MAX_PASSWORD_LEN: usize = 72;
pub const BCRYPT_COST: u32 = 12;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistrationRequest {
    pub username: String,
    pub password: String,
}

/// Trims and lowercases a username so `Lukas` and `lukas` are the same account.
pub fn normalize_username(name: &str) -> String {
    name.trim().to_lowercase()
}

pub fn allowed_username(name: &str) -> bool {
    name.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, '_' | '.' | '-'))
}

/// Reports the first problem with the input, or nothing if it is acceptable. This is the
/// trust boundary: the client form only checks the fields roughly, here the values become
/// valid or the request is rejected.
pub fn validate(username: &str, password: &str) -> Option<String> {
    let length = username.chars().count();
    if !(MIN_USERNAME_LEN..=MAX_USERNAME_LEN).contains(&length) {
        return Some("username must be 3-32 characters".to_string());
    }
    if !allowed_username(username) {
        return Some("username may only contain letters, digits, underscore, dot and hyphen".to_string());
    }
    if password.len() < MIN_PASSWORD_LEN {
        return Some("password must be at least 8 characters".to_string());
    }
    if password.len() > MAX_PASSWORD_LEN {
        return Some("password must be at most 72 characters".to_string());
    }
    if password.chars().any(sanitize::is_control) {
        return Some("password must not contain control characters".to_string());
    }
    None
}

pub async fn handle(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many registrations from this address, try again later", retry);
    }

    let body = match jsonbody::read_object::<RegistrationRequest>(req.into_body(), "\"username\" and \"password\"").await {
        Ok(body) => body,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    let username = normalize_username(&body.username);
    if let Some(message) = validate(&username, &body.password) {
        return respond::error(StatusCode::BAD_REQUEST, &message);
    }

    // Hashed before the insert is attempted, so the time an answer takes does not reveal
    // whether the username exists. The plain password is never stored or returned.
    let hash = match bcrypt::hash(&body.password, BCRYPT_COST) {
        Ok(hash) => hash,
        Err(_) => return respond::error(StatusCode::INTERNAL_SERVER_ERROR, "could not hash password"),
    };

    let mut created = user::User {
        id: 0,
        username,
        password_hash: hash,
    };

    // The insert takes the model by reference, so the row that was stored is what comes back
    // and what the answer shows.
    let saved = db::call(&state.db, move |conn| {
        user::insert(conn, &mut created)?;
        Ok(created)
    })
    .await;

    match saved {
        // The hash is skipped by the model, so it cannot reach the answer.
        Ok(created) => respond::json(StatusCode::CREATED, &created),
        Err(err) => respond::answer(&err, "could not save user"),
    }
}

pub fn routes(state: AppState) -> Router {
    Router::new().route("/api/register", post(handle)).with_state(state)
}
