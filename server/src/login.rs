use std::sync::LazyLock;

use axum::extract::{Request, State};
use axum::http::StatusCode;
use axum::response::Response;
use axum::routing::post;
use axum::Router;

use crate::{clock, db, jsonbody, ratelimit, register, respond, respond::Failure, session, state::AppState, user};

/// Compared when a login names an unknown user, so the response time does not reveal whether
/// the username exists — the same reasoning as the hash-before-insert order in `register`.
/// Its value is meaningless; it is generated once at startup so the first unknown user does
/// not pay for generating it.
pub static DUMMY_HASH: LazyLock<String> = LazyLock::new(|| {
    bcrypt::hash("timing equalizer", register::BCRYPT_COST).expect("the dummy hash")
});

pub async fn handle(State(state): State<AppState>, req: Request) -> Response {
    let (ok, retry) = ratelimit::allow(&state.limiter, &ratelimit::client_ip(&req));
    if !ok {
        return respond::rate_limited("too many logins from this address, try again later", retry);
    }

    let body = match jsonbody::read_object::<register::RegistrationRequest>(req.into_body(), "\"username\" and \"password\"").await {
        Ok(body) => body,
        Err(message) => return respond::error(StatusCode::BAD_REQUEST, &message),
    };

    // The same field rules as registration, so there is one source for them.
    let username = register::normalize_username(&body.username);
    if let Some(message) = register::validate(&username, &body.password) {
        return respond::error(StatusCode::BAD_REQUEST, &message);
    }

    // The answer always says the same thing: it never distinguishes "no such user" from
    // "wrong password", so callers cannot enumerate usernames.
    let found = match db::call(&state.db, move |conn| user::get_by_username(conn, &username)).await {
        Ok(found) => found,
        Err(Failure::NoRows) => {
            // A comparison that costs the same as a real one, so this branch is not faster.
            let _ = bcrypt::verify(&body.password, &DUMMY_HASH);
            return respond::error(StatusCode::UNAUTHORIZED, "username or password is wrong");
        }
        Err(err) => return respond::answer(&err, "could not load user"),
    };

    // The comparison is constant time for a given hash length, which is what a timing-safe
    // password check needs.
    if !bcrypt::verify(&body.password, &found.password_hash).unwrap_or(false) {
        return respond::error(StatusCode::UNAUTHORIZED, "username or password is wrong");
    }

    let token = match session::new_token() {
        Ok(token) => token,
        Err(err) => return respond::answer(&err, "could not create session"),
    };

    let now = clock::unix_now();
    let row = session::Session {
        token_hash: session::hash_token(&token),
        user_id: found.id,
        created_at: now,
        expires_at: now + session::SESSION_TTL_SECONDS,
    };

    // Only the hash is stored; this answer is the one time the client sees the token.
    let saved = db::call(&state.db, move |conn| {
        session::insert(conn, &row)?;
        Ok(row)
    })
    .await;

    match saved {
        Ok(saved) => respond::json(
            StatusCode::OK,
            &serde_json::json!({ "token": token, "expires_at": saved.expires_at }),
        ),
        Err(err) => respond::answer(&err, "could not save session"),
    }
}

pub fn routes(state: AppState) -> Router {
    Router::new().route("/api/login", post(handle)).with_state(state)
}
