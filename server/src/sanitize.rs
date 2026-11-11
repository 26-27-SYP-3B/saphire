/// The control characters a value may not contain: C0 plus DEL. Names are shown to a
/// person and a password is typed by one, so both use this one rule.
pub fn is_control(c: char) -> bool {
    (c as u32) < 0x20 || c == '\u{7f}'
}

/// Copies `value` without control characters, at most `max_len` characters. A name is shown
/// to a person, so this counts characters, not bytes — counting bytes would cut a multi-byte
/// letter in half. Both a title and a playlist name are cleaned here, so they agree on what
/// is acceptable.
pub fn without_control_chars(value: &str, max_len: usize) -> String {
    let cleaned: String = value.chars().filter(|c| !is_control(*c)).take(max_len).collect();
    cleaned.trim().to_string()
}
