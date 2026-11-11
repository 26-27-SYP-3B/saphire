/// The wall clock, in the seconds the database stores. Only for timestamps that a client
/// reads back: nothing here trusts it for the rate limiter, which uses a monotonic clock.
pub fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|since| since.as_secs() as i64)
        .unwrap_or(0)
}
