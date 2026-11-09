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
      }
    } catch (_) {
      return SettingsStore(storage);
    }
    return store;
  }

  void save(String serverBase) {
    this.serverBase = serverBase;

    // The repositories read apiBaseUrl while they work, so a new server takes
    // effect without rebuilding them.
    apiBaseUrl = serverBase;

    _storage?.write(key: _key, value: jsonEncode({'server': serverBase})).ignore();
  }
}
