/// A path value that must be a plain positive number, the same rule as a song id. Digits only,
/// no sign, no leading zeros: `0` and `-1` are not ids, and `0004` would be the same slot
/// under two names. `label` is what the answer calls it.
pub fn parse_positive(value: &str, label: &str) -> Result<i64, String> {
    let digits = !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit());
    if !digits || value.starts_with('0') {
        return Err(format!("the {label} must be a positive number"));
    }

    // The characters are digits, so a failure here can only be a value too large to be an id,
    // and the answer must say that instead of "not a number".
    match value.parse::<i64>() {
        Ok(number) => Ok(number),
        Err(_) => Err(format!("the {label} is too large")),
    }
}
