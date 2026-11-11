import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _prefix = 'playlist_cover:';

/// The cover images of the playlists, kept on this device.
///
/// The server stores a playlist as a name and song positions only (api-docs.md), so there
/// is nowhere to upload a picture. A cover therefore belongs to this device, the same way
/// a local playlist does. The key says which playlist it is: `server:<address>:<id>` or
/// `local:<name>`, so a server playlist and a local one cannot share a picture, and a
/// picture taken on one server does not appear on another.
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
      // One entry per cover: a storage that is full refuses one image instead of taking
      // the other covers with it.
      for (final entry in (await storage.readAll()).entries) {
        if (!entry.key.startsWith(_prefix)) continue;
        store._covers[entry.key.substring(_prefix.length)] = base64Decode(entry.value);
      }
    } catch (_) {
      return CoverStore(storage);
    }
    return store;
  }

  Uint8List? operator [](String key) => _covers[key];

  /// Keeps the image. Returns false when the device's storage refused it; the cover still
  /// shows for this run, which is all a full or broken storage allows.
  Future<bool> save(String key, Uint8List bytes) async {
    _covers[key] = bytes;
    final storage = _storage;
    if (storage == null) return true;
    try {
      await storage.write(key: '$_prefix$key', value: base64Encode(bytes));
      return true;
    } catch (_) {
      return false;
    }
  }
}
