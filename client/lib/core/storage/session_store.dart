import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// One entry: the token and its expiry. Two entries would be two writes, and the
/// web plugin can mint a new encryption key for each parallel write, which leaves
/// the first value unreadable.
const _key = 'session';

/// Holds the session token that the server gave us at login. Secure storage keeps
/// it across a restart, so a returning user does not have to log in again.
class SessionStore {
  SessionStore([this._storage]);

  /// Null in tests: the plugin has no platform there, so those stores stay in
  /// memory, which is all they need.
  final FlutterSecureStorage? _storage;

  String? _token;
  String? _streamToken;
  int _expiresAt = 0;

  /// The token the browser player puts in a stream URL. It is a separate secret, so a URL
  /// cannot be used to read playlists, the queue or the account.
  String? get streamToken => isLoggedIn ? _streamToken : null;

  /// The store with the token the last run saved. A broken keychain must not keep
  /// the app from starting: the user just logs in again.
  static Future<SessionStore> restore() async {
    const storage = FlutterSecureStorage();
    final store = SessionStore(storage);
    try {
      final saved = await storage.read(key: _key);
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        store._token = data['token'] as String?;
        store._streamToken = data['stream_token'] as String?;
        store._expiresAt = (data['expires_at'] as num?)?.toInt() ?? 0;

        // A session written by a build before the stream token exists cannot play in a
        // browser: the audio element sends no header. Ask for one login instead of failing
        // every song. Native clients keep working with the session header.
        if (kIsWeb && store._token != null && store._streamToken == null) {
          store._token = null;
          store._expiresAt = 0;
          await storage.delete(key: _key);
        }
      }
    } catch (_) {
      return SessionStore(storage);
    }
    return store;
  }

  bool get isLoggedIn {
    if (_token == null) return false;
    // The server answers with expires_at as a Unix timestamp in seconds; an
    // expired session is treated like no session at all.
    if (DateTime.now().millisecondsSinceEpoch ~/ 1000 > _expiresAt) {
      unawaited(clear());
      return false;
    }
    return true;
  }

  String? get token => isLoggedIn ? _token : null;

  void save(String token, int expiresAt, [String? streamToken]) {
    _token = token;
    _streamToken = streamToken;
    _expiresAt = expiresAt;
    // Storage only has to survive a restart, so the answer is not awaited and a
    // failed write leaves the session working in memory.
    _storage?.write(key: _key, value: jsonEncode({'token': token, 'stream_token': streamToken, 'expires_at': expiresAt})).ignore();
  }

  /// Awaited where the delete has to finish before the next write (the setup and the
  /// settings screens). A failed delete leaves the in-memory session gone anyway.
  Future<void> clear() async {
    _token = null;
    _streamToken = null;
    _expiresAt = 0;
    try {
      await _storage?.delete(key: _key);
    } catch (_) {}
  }
}
