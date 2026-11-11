import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/api_config.dart';

const _key = 'settings';

/// What the guided setup decided (which server the app talks to) and what the user
/// chose when the app had no session yet (run without a server). Both belong to one
/// run, so they are one entry: like SessionStore, a test store stays in memory.
class SettingsStore {
  SettingsStore([this._storage]);

  /// Null in tests: the plugin has no platform there, so the store stays in memory.
  final FlutterSecureStorage? _storage;

  String? serverBase;
  bool localMode = false;

  /// The settings the last run saved. A broken keychain must not keep the app from
  /// starting: it then behaves like a first run.
  static Future<SettingsStore> restore() async {
    const storage = FlutterSecureStorage();
    final store = SettingsStore(storage);
    try {
      final saved = await storage.read(key: _key);
      if (saved == null) return store;

      final data = jsonDecode(saved) as Map<String, dynamic>;
      store.serverBase = data['server'] as String?;
      store.localMode = data['local'] == true;
      // The only place the address the app talks to is set, so the store and the
      // repositories cannot disagree.
      if (store.serverBase != null) apiBaseUrl = store.serverBase!;
    } catch (_) {
      return SettingsStore(storage);
    }
    return store;
  }

  /// Saves what this run decided. Nothing passed in keeps its current value, so the
  /// two choices cannot overwrite each other.
  Future<void> save({String? server, bool? localMode}) async {
    if (server != null) {
      serverBase = server;
      // The repositories read apiBaseUrl while they work, so a new server takes
      // effect without rebuilding them.
      apiBaseUrl = server;
    }
    if (localMode != null) this.localMode = localMode;

    // Awaited: the settings are what the next start reads, and two writes to the same
    // key in parallel cannot be handled by the web plugin (see session_store.dart). A
    // broken keychain must not block the caller: the values work in memory for this run.
    try {
      await _storage?.write(
        key: _key,
        value: jsonEncode({'server': serverBase, 'local': this.localMode}),
      );
    } catch (_) {}
  }
}
