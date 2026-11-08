import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';

/// In memory through the package's own test platform, so no device is needed.
void useEmptyStorage() => FlutterSecureStorage.setMockInitialValues({});

int inOneHour() => DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;

void main() {
  test('a session survives a restart', () async {
    useEmptyStorage();

    SessionStore(FlutterSecureStorage()).save('a' * 64, inOneHour());
    // save() does not wait for the write, so give the write its turn.
    await Future<void>.delayed(Duration.zero);

    final restored = await SessionStore.restore();

    expect(restored.isLoggedIn, true);
    expect(restored.token, 'a' * 64);
  });

  test('an expired session does not come back logged in', () async {
    useEmptyStorage();
    // A token that was saved last week.
    SessionStore(FlutterSecureStorage()).save('b' * 64, inOneHour() - 8 * 24 * 3600);
    await Future<void>.delayed(Duration.zero);

    final restored = await SessionStore.restore();

    expect(restored.isLoggedIn, false);
    expect(restored.token, null);
  });
}
