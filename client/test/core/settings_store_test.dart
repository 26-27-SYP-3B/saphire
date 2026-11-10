import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/settings_store.dart';

/// A keychain that refuses every call, like a locked one.
class _BrokenStorage implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('keychain locked');
}

void main() {
  test('the server the first run saved comes back on the next start', () async {
    FlutterSecureStorage.setMockInitialValues({});

    await SettingsStore(FlutterSecureStorage()).save('https://musik.meinserver.at');

    final restored = await SettingsStore.restore();

    // The whole point of the store: the address, and the value the repositories read.
    expect(restored.serverBase, 'https://musik.meinserver.at');
    expect(apiBaseUrl, 'https://musik.meinserver.at');
  });

  test('an unreadable settings entry behaves like a first run', () async {
    FlutterSecureStorage.setMockInitialValues({'settings': 'not json'});

    final restored = await SettingsStore.restore();

    expect(restored.serverBase, isNull);
  });

  // The setup screen awaits save() before it goes to the login; a throw here used to
  // leave it on "Wird geprüft…" forever.
  test('a save the keychain refuses still lets this run use the server', () async {
    final store = SettingsStore(_BrokenStorage());

    await store.save('https://musik.meinserver.at');

    expect(store.serverBase, 'https://musik.meinserver.at');
    expect(apiBaseUrl, 'https://musik.meinserver.at');
  });
}
