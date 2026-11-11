use axum::body::Body;
use http_body_util::{BodyExt, Limited};
use serde::de::DeserializeOwned;

pub const MAX_BODY_BYTES: usize = 4 << 10;

/// Reads one strict JSON object of at most `MAX_BODY_BYTES`. `expected` is the field this
/// endpoint wants, so the answer names it. Every endpoint that takes a body reads it this
/// way, so they all reject the same things: a second object, an unknown field, a body over
/// the limit.
pub async fn read_object<T: DeserializeOwned>(body: Body, expected: &str) -> Result<T, String> {
    // The limit is enforced while reading, not after: a body over it is refused the same
    // way one that cannot be parsed is.
    let collected = match Limited::new(body, MAX_BODY_BYTES).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(_) => return Err(one_object(expected)),
    };

    let text = match std::str::from_utf8(&collected) {
        Ok(text) => text,
        Err(_) => return Err(one_object(expected)),
    };

    let mut deserializer = serde_json::Deserializer::from_str(text);
    let value = match T::deserialize(&mut deserializer) {
        Ok(value) => value,
        Err(_) => return Err(one_object(expected)),
    };

    // Anything after the object is a separate answer, so the caller knows the body held more
    // than the one object it was asked for. `end` is what decides it: trailing text that is not
    // a JSON value is still trailing content, so parsing what is left would accept
    // `{"name":"x"} garbage`. Trailing whitespace is not content.
    if deserializer.end().is_err() {
        return Err("body must contain exactly one JSON object".to_string());
    }

    Ok(value)
}

fn one_object(expected: &str) -> String {
    format!("body must be one JSON object with {expected}")
}
