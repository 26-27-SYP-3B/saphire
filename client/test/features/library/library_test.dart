import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';

import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

// The library as GET /api/music answers it: id and title, and nothing else. Numbers arrive
// as doubles, so the model reads them through num.
const libraryAnswer = [
  {'id': 4.0, 'title': 'lied.wav'},
  {'id': 8.0, 'title': 'Technogal.mp3'},
];

void main() {
  test('reads a library answer', () async {
    final adapter = StubAdapter(200, libraryAnswer);
    final repository = LibraryRepository(Dio()..httpClientAdapter = adapter, loggedIn());

    final songs = await repository.list();

    expect(songs.map((song) => song.title), ['lied.wav', 'Technogal.mp3']);
    expect(songs.first.id, 4);
    expect(adapter.lastOptions?.uri.path, '/api/music');
    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer ${'a' * 64}');
  });

  // An empty library answers [], never null. A page must not read that as an error.
  test('an empty library is an empty list, not a missing value', () async {
    final repository = LibraryRepository(Dio()..httpClientAdapter = StubAdapter(200, <Object>[]), loggedIn());

    expect(await repository.list(), isEmpty);
  });

  test('the message of the server is passed on', () async {
    final repository = LibraryRepository(
      Dio()..httpClientAdapter = StubAdapter(401, {'error': 'session is not valid or expired'}),
      SessionStore(),
    );

    expect(
      () => repository.list(),
      throwsA(isA<LibraryException>().having((error) => error.message, 'message', 'session is not valid or expired')),
    );
  });

  // Without a session the header is not built at all, so the server answers with its own
  // missing-header message rather than an unknown session.
  test('a call without a session sends no authorization header', () async {
    final adapter = StubAdapter(401, {'error': 'authorization header with a Bearer token is missing'});
    final repository = LibraryRepository(Dio()..httpClientAdapter = adapter, SessionStore());

    await expectLater(repository.list(), throwsA(isA<LibraryException>()));
    expect(adapter.lastOptions?.headers['Authorization'], isNull);
  });
}
