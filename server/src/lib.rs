//! One module per domain area, as the Go version had one file per area. Every answer is
//! written through the helpers in `respond`.

pub mod app;
pub mod clock;
pub mod cors;
pub mod db;
pub mod hex;
pub mod jsonbody;
pub mod login;
pub mod music;
pub mod pathvalue;
pub mod playlist;
pub mod queue;
pub mod ratelimit;
pub mod register;
pub mod respond;
pub mod sanitize;
pub mod session;
pub mod state;
pub mod staticfiles;
pub mod user;
