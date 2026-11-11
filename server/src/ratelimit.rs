use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use axum::extract::ConnectInfo;
use axum::extract::Request;

/// A per-IP token bucket. Separate per endpoint group, so a login flood cannot starve
/// registration and a player that reads its queue cannot stop the library.
pub struct RateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
    capacity: usize,
    refill: Duration,
}

struct Bucket {
    tokens: f64,
    last: Instant,
}

pub fn new(capacity: usize, refill: Duration) -> RateLimiter {
    RateLimiter {
        buckets: Mutex::new(HashMap::new()),
        capacity,
        refill,
    }
}

/// Reports whether a request from `ip` fits in the bucket. When it does not, the second
/// value is the seconds until the next token refills, so a handler can answer with an
/// honest `Retry-After` instead of a fixed guess that overstates the wait.
///
/// A bucket that has been idle long enough to be fully refilled is equivalent to a fresh
/// one, so stale entries are pruned and the map stays bounded to the addresses that are
/// actually active.
pub fn allow(limiter: &RateLimiter, ip: &str) -> (bool, u64) {
    let mut buckets = limiter.buckets.lock().expect("the limiter lock");
    let now = Instant::now();

    if !buckets.contains_key(ip) {
        prune(&mut buckets, now, limiter.capacity, limiter.refill);
    }

    let bucket = buckets
        .entry(ip.to_string())
        .or_insert_with(|| Bucket {
            tokens: limiter.capacity as f64,
            last: now,
        });

    bucket.tokens += now.duration_since(bucket.last).as_secs_f64() / limiter.refill.as_secs_f64();
    if bucket.tokens > limiter.capacity as f64 {
        bucket.tokens = limiter.capacity as f64;
    }
    bucket.last = now;

    if bucket.tokens < 1.0 {
        return (false, ((1.0 - bucket.tokens) * limiter.refill.as_secs_f64()).ceil() as u64);
    }

    bucket.tokens -= 1.0;
    (true, 0)
}

fn prune(buckets: &mut HashMap<String, Bucket>, now: Instant, capacity: usize, refill: Duration) {
    // A bucket idle for a full refill of the capacity would have been indistinguishable
    // from a new one, so dropping it cannot change an answer.
    let idle = refill * capacity as u32;
    let stale: Vec<String> = buckets
        .iter()
        .filter(|(_, bucket)| now.duration_since(bucket.last) >= idle)
        .map(|(ip, _)| ip.clone())
        .collect();
    for ip in stale {
        buckets.remove(&ip);
    }
}

/// The address a bucket belongs to. `X-Forwarded-For` is trusted when running behind a
/// reverse proxy; otherwise the peer address, with the port split off.
pub fn client_ip(req: &Request) -> String {
    if let Some(forwarded) = req.headers().get("x-forwarded-for") {
        let first = forwarded
            .to_str()
            .unwrap_or_default()
            .split(',')
            .next()
            .unwrap_or_default()
            .trim();
        if !first.is_empty() {
            return peer_key(first);
        }
    }

    match req.extensions().get::<ConnectInfo<SocketAddr>>() {
        Some(info) => peer_key(&info.0.to_string()),
        // An unknown peer shares one bucket.
        None => String::new(),
    }
}

/// Turns a peer address as the server reports it into the key of its bucket. A bracketed
/// IPv6 keeps its address and zone; a port is split off, so `127.0.0.1:8080` and `::1:8080`
/// do not fall into one shared bucket.
pub fn peer_key(remote: &str) -> String {
    let host = match remote.find(']') {
        // Bracketed: the address is inside the brackets and the port follows them.
        Some(end) => remote[..end].trim_matches('['),
        // Plain address and port, or an address with no port at all.
        None => match remote.rfind(':') {
            Some(end) => &remote[..end],
            None => remote,
        },
    };

    // A zone is part of the address, not of the port, so it belongs to the key.
    match host.split_once('%') {
        Some((address, zone)) => match address.parse::<IpAddr>() {
            Ok(parsed) => format!("{parsed}%{zone}"),
            Err(_) => String::new(),
        },
        None => match host.parse::<IpAddr>() {
            Ok(parsed) => parsed.to_string(),
            Err(_) => String::new(),
        },
    }
}
