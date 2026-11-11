import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/api_config.dart';

const _key = 'settings';

/// What the guided setup decided: which server the app talks to. Like
/// SessionStore, a test store stays in memory.
class SettingsStore {
  SettingsStore([this._storage]);

  final FlutterSecureStorage? _storage;

  String? serverBase;

  /// The settings the last run saved. A broken keychain must not keep the app from
  /// starting: it then behaves like a first run.
  static Future<SettingsStore> restore() async {
    const storage = FlutterSecureStorage();
    final store = SettingsStore(storage);
    try {
      final saved = await storage.read(key: _key);
      if (saved != null) {
        final data = jsonDecode(saved) as Map<String, dynamic>;
        store.serverBase = data['server'] as String?;
        // The only place the address the app talks to is set, so the store and the
        // repositories cannot disagree.
        if (store.serverBase != null) apiBaseUrl = store.serverBase!;
      }
    } catch (_) {
      return SettingsStore(storage);
    }
    return store;
  }

  Future<void> save(String serverBase) async {
    this.serverBase = serverBase;

    // The repositories read apiBaseUrl while they work, so a new server takes
    // effect without rebuilding them.
    apiBaseUrl = serverBase;

    // Awaited, unlike the session write: remembering the server is what this store is
    // for, and the login write that follows can otherwise run in parallel with it,
    // which the web plugin cannot handle (see session_store.dart). A broken keychain
    // must not block the caller: the address works in memory for this run.
    try {
      await _storage?.write(key: _key, value: jsonEncode({'server': serverBase}));
    } catch (_) {}
  }
}
