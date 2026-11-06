/// Holds the session token that the server gave us at login. In memory only:
/// the app cannot keep it across a restart yet, that needs a storage plugin.
class SessionStore {
  String? _token;
  int _expiresAt = 0;

  bool get isLoggedIn {
    if (_token == null) return false;
    // The server answers with expires_at as a Unix timestamp in seconds; an
    // expired session is treated like no session at all.
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 > _expiresAt) {
      clear();
      return false;
    }
    return true;
  }

  String? get token => isLoggedIn ? _token : null;

  void save(String token, int expiresAt) {
    _token = token;
    _expiresAt = expiresAt;
  }

  void clear() {
    _token = null;
    _expiresAt = 0;
  }
}
