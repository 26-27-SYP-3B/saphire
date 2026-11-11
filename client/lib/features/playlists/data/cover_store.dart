import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _key = 'playlist_covers';

/// The cover images of the playlists, kept on this device.
///
/// The server stores a playlist as a name and song positions only (api-docs.md), so there
/// is nowhere to upload a picture. A cover therefore belongs to this device, the same way
/// a local playlist does. The key says which playlist it is: `server:<id>` or
/// `local:<name>`, so a server playlist and a local one cannot share a picture.
class CoverStore {
  CoverStore([this._storage]);

  /// Null in tests: the plugin has no platform there, so the covers stay in memory.
  final FlutterSecureStorage? _storage;

  final Map<String, Uint8List> _covers = {};

  /// A broken keychain must not keep the app from starting: it then looks like a first
  /// run, the same way SessionStore and LocalLibrary handle it.
  static Future<CoverStore> restore() async {
    const storage = FlutterSecureStorage();
    final store = CoverStore(storage);
    try {
      final saved = await storage.read(key: _key);
      if (saved == null) return store;

      final data = jsonDecode(saved) as Map<String, dynamic>;
      for (final entry in data.entries) {
        store._covers[entry.key] = base64Decode(entry.value as String);
      }
    } catch (_) {
      return CoverStore(storage);
    }
    return store;
  }

  Uint8List? operator [](String key) => _covers[key];

  /// Writes are chained for the same reason as in LocalLibrary: two writes to the same key
  /// in parallel are not something the web plugin can handle.
  Future<void> _pending = Future.value();

  void save(String key, Uint8List bytes) {
    _covers[key] = bytes;
    _pending = _pending.then((_) async {
      final storage = _storage;
      if (storage == null) return;
      try {
        await storage.write(
          key: _key,
          value: jsonEncode({for (final cover in _covers.entries) cover.key: base64Encode(cover.value)}),
        );
      } catch (_) {
        // In memory the cover still shows for this run, which is all a broken keychain allows.
      }
    });
  }
}
