import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/utils/pick_audio.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';
import 'package:saphire_client/features/library/presentation/library_screen.dart';
import 'package:saphire_client/features/player/data/player.dart';
import 'package:saphire_client/features/playlists/data/playlist_store.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';
import 'package:saphire_client/features/upload/domain/track.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/stub_adapter.dart';

// Three rows, so all three orders the page can be sorted by come out different:
// Titel gives Alle Songs, Bohne, Neutrone; Interpret gives Bohne, Neutrone, Alle
// Songs; Hinzugefügt am gives Neutrone, Alle Songs, Bohne. With two rows two of
// those orders would be the same, and a test could pass while the wrong branch
// decided it.
//
// The artist and the length are what the server read out of the file (api-docs.md,
// GET /api/music); the row with no length shows a dash instead of a guess.
const libraryAnswer = [
  {'id': 4.0, 'title': 'Neutrone (Remix)', 'artist': 'Kraftwerk', 'duration_ms': 215000.0, 'uploaded_at': 300.0},
  {'id': 8.0, 'title': 'Alle Songs', 'artist': 'Zukunft', 'duration_ms': 0.0, 'uploaded_at': 200.0},
  {'id': 9.0, 'title': 'Bohne', 'artist': 'Anna', 'duration_ms': 121000.0, 'uploaded_at': 100.0},
];

SessionStore loggedIn() =>
    SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

/// The library screen with a session, so the repository sends a token. The screen is
/// pumped on its own here, so the router guard is not part of these tests; the
/// navigation test below covers the guard. Every answer a test needs comes from the
/// stub adapter: the list first, then the upload.
Future<PlaylistStore> openLibrary(
  WidgetTester tester, {
  Object libraryBody = libraryAnswer,
  StubAdapter? libraryAdapter,
  StubAdapter? uploadAdapter,
  PickAudio? pickAudio,
  Player? player,
}) async {
  // The test font draws every glyph as wide as the font size, so this page needs
  // more room than the default test window.
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final session = loggedIn();
  final adapter = libraryAdapter ?? StubAdapter(200, libraryBody);
  final playlists = PlaylistStore();

  await tester.pumpWidget(
    MaterialApp(
      home: LibraryScreen(
        library: LibraryRepository(Dio()..httpClientAdapter = adapter, session),
        player: player ?? Player(session, (url, headers) async {}),
        playlists: playlists,
        uploads: UploadRepository(Dio()..httpClientAdapter = uploadAdapter ?? adapter, session),
        pickAudio: pickAudio ?? (() async => [(name: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3]))]),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return playlists;
}

Future<void> openMenu(WidgetTester tester, String title) async {
  await tester.tap(find.byTooltip('Aktionen für $title'));
  await tester.pumpAndSettle();
}

Future<void> pickSort(WidgetTester tester, String key) async {
  await tester.tap(find.byType(DropdownButton<String>));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sortieren: $key'));
  await tester.pumpAndSettle();
}

/// The rows as the page shows them, top to bottom. A row can only be told apart by
/// the text it draws, so the titles are what the order is read from.
List<String> shownOrder(WidgetTester tester, List<String> titles) {
  final rows = [for (final title in titles) (title, tester.getTopLeft(find.text(title)).dy)]
    ..sort((a, b) => a.$2.compareTo(b.$2));

  return [for (final row in rows) row.$1];
}

void main() {
  test('reads the library answer as songs', () async {
    final tracks = await LibraryRepository(
      Dio()..httpClientAdapter = StubAdapter(200, libraryAnswer),
      loggedIn(),
    ).list();

    expect(tracks.map((track) => track.title), ['Neutrone (Remix)', 'Alle Songs', 'Bohne']);
    expect(tracks.first.artist, 'Kraftwerk');
    // JSON numbers arrive as double on the web, so the length must survive the cast.
    expect(tracks.first.durationMs, 215000);
    expect(tracks[1].durationMs, 0);
    expect(tracks.last.durationMs, 121000);
  });

  // A row that is not an object cannot be half a song, so the answer is an error.
  test('a row that is not an object is an error', () async {
    await expectLater(
      LibraryRepository(Dio()..httpClientAdapter = StubAdapter(200, [4.0]), loggedIn()).list(),
      throwsA(isA<LibraryException>()),
    );
  });

  // The artist is what the file's tags said. Only where the file does not say one is
  // the name used, and a name that does not say it shows nothing.
  test('the artist is the server field, or the name when the file has no tags', () {
    expect(artistOf(Track(id: 1, title: 'Neutrone (Remix)', artist: 'Kraftwerk')), 'Kraftwerk');
    expect(artistOf(Track(id: 2, title: 'Kraftwerk - Technogal.mp3')), 'Kraftwerk');
    expect(artistOf(Track(id: 3, title: 'Alle Songs.mp3')), '');
    expect(artistFromName('A - Titel.mp3'), 'A');
  });

  test('a length is shown as minutes and seconds, a file that cannot be measured as a dash', () {
    expect(durationOf(Track(id: 1, title: 'x', durationMs: 215000)), '3:35');
    expect(durationOf(Track(id: 2, title: 'x', durationMs: 61000)), '1:01');
    expect(durationOf(Track(id: 3, title: 'x')), '–');
  });

  testWidgets('the library shows every song with its artist and length', (tester) async {
    await openLibrary(tester);

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Kraftwerk · 3:35'), findsOneWidget);
    expect(find.text('Alle Songs'), findsOneWidget);
    // A file the server could not measure shows a dash, not a guessed number.
    expect(find.text('Zukunft · –'), findsOneWidget);
    expect(find.text('Anna · 2:01'), findsOneWidget);
  });

  testWidgets('an empty library says so and offers an upload', (tester) async {
    await openLibrary(tester, libraryBody: []);

    expect(find.textContaining('Bibliothek ist noch leer'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Song hochladen'), findsOneWidget);
  });

  // Only [] means empty. An answer that is not the documented list is an error the
  // user is told about, not a library that looks empty.
  testWidgets('an answer that is not the documented list shows an error', (tester) async {
    await openLibrary(tester, libraryBody: {'id': 4.0});

    expect(find.text('Die Antwort des Servers konnte nicht gelesen werden.'), findsOneWidget);
    expect(find.textContaining('Bibliothek ist noch leer'), findsNothing);
  });

  testWidgets('the search field only shows what matches', (tester) async {
    await openLibrary(tester);

    // The artist is a field of its own here, so searching by it finds a song whose
    // name does not contain the word.
    await tester.enterText(find.byType(TextField), 'zukunft');
    await tester.pumpAndSettle();

    expect(find.text('Alle Songs'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
    expect(find.text('Bohne'), findsNothing);

    await tester.enterText(find.byType(TextField), 'neutrone');
    await tester.pumpAndSettle();

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Alle Songs'), findsNothing);
    expect(find.text('Bohne'), findsNothing);
  });

  testWidgets('the sort selection orders the rows by what was picked', (tester) async {
    await openLibrary(tester);

    // Titel, the default: what starts with A comes first.
    const titles = ['Alle Songs', 'Bohne', 'Neutrone (Remix)'];
    expect(shownOrder(tester, titles), titles);

    await pickSort(tester, 'Interpret');

    // Interpret: the artists decide the order, so this is a different order than by
    // title — the rows are the same rows, only moved.
    expect(shownOrder(tester, titles), ['Bohne', 'Neutrone (Remix)', 'Alle Songs']);

    await pickSort(tester, 'Hinzugefügt am');

    // Hinzugefügt am: the newer song comes first, which is a different order than
    // either of the other two, so this branch is really the one that decided it.
    expect(shownOrder(tester, titles), ['Neutrone (Remix)', 'Alle Songs', 'Bohne']);
  });

  // The comparison is case-insensitive, so a name that starts with a small letter
  // comes before one that starts with a capital. With the code points alone the
  // capital would win, and this test would pass for the wrong reason.
  testWidgets('the sort does not care about case', (tester) async {
    await openLibrary(
      tester,
      libraryBody: [
        {'id': 1.0, 'title': 'Zeh', 'artist': 'Berta', 'duration_ms': 0.0, 'uploaded_at': 1.0},
        {'id': 2.0, 'title': 'ahn', 'artist': 'yta', 'duration_ms': 0.0, 'uploaded_at': 2.0},
      ],
    );

    expect(shownOrder(tester, ['Zeh', 'ahn']), ['ahn', 'Zeh']);

    await pickSort(tester, 'Interpret');
    expect(shownOrder(tester, ['Zeh', 'ahn']), ['Zeh', 'ahn']);
  });

  // What the sort key cannot decide is decided by the id, so the same rows keep the
  // same order on every rebuild. Here both titles are the same when case is ignored
  // and both artists and dates are equal, so only the id can tell them apart:
  // ascending for the names, descending for the date, which is the direction that
  // key already reads in.
  testWidgets('rows the sort key cannot tell apart are ordered by id', (tester) async {
    await openLibrary(
      tester,
      libraryBody: [
        {'id': 4.0, 'title': 'Gleich', 'artist': 'Zukunft', 'duration_ms': 0.0, 'uploaded_at': 5.0},
        {'id': 8.0, 'title': 'gleich', 'artist': 'Zukunft', 'duration_ms': 0.0, 'uploaded_at': 5.0},
      ],
    );

    expect(shownOrder(tester, ['Gleich', 'gleich']), ['Gleich', 'gleich']);

    await pickSort(tester, 'Hinzugefügt am');
    expect(shownOrder(tester, ['Gleich', 'gleich']), ['gleich', 'Gleich']);
  });

  testWidgets('playing a song shows it in the bar', (tester) async {
    final played = <String>[];

    await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      player: Player(loggedIn(), (url, headers) async => played.add(url)),
    );

    await tester.tap(find.byTooltip('Abspielen'));
    await tester.pumpAndSettle();

    expect(played.single, contains('/api/music/4'));
    expect(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('Neutrone (Remix)')),
      findsOneWidget,
    );
  });

  // The row itself can be tapped, so playing a song does not need the small icon.
  testWidgets('clicking the row plays the song', (tester) async {
    final played = <String>[];

    await openLibrary(
      tester,
      libraryBody: [libraryAnswer[1]],
      player: Player(loggedIn(), (url, headers) async => played.add(url)),
    );

    await tester.tap(find.text('Alle Songs'));
    await tester.pumpAndSettle();

    expect(played.single, contains('/api/music/8'));
    expect(
      find.descendant(of: find.byType(PlayerBar), matching: find.text('Alle Songs')),
      findsOneWidget,
    );
  });

  // The message is ours, not the player's own text, so it stays readable.
  testWidgets('a song the player cannot start says so in the bar', (tester) async {
    await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      player: Player(loggedIn(), (url, headers) async => throw Exception('no audio platform in a test')),
    );

    await tester.tap(find.byTooltip('Abspielen'));
    await tester.pumpAndSettle();

    expect(find.text('Der Song konnte nicht abgespielt werden.'), findsOneWidget);
  });

  testWidgets('the context menu adds a song to the queue and to a playlist', (tester) async {
    final store = await openLibrary(tester, libraryBody: [libraryAnswer.first]);

    await openMenu(tester, 'Neutrone (Remix)');
    await tester.tap(find.text('Zur Warteschlange hinzufügen'));
    await tester.pumpAndSettle();

    // Nothing has been played, so the bar names the queued song by its title.
    expect(find.textContaining('Als nächstes: Neutrone'), findsOneWidget);

    await openMenu(tester, 'Neutrone (Remix)');
    await tester.tap(find.text('Zur neuen Playlist „Meine Playlist“'));
    await tester.pumpAndSettle();

    expect(store.names, ['Meine Playlist']);
    expect(store.songs('Meine Playlist'), [4]);
  });

  testWidgets('an uploaded song is added to the library', (tester) async {
    final adapter = StubAdapter(200, [libraryAnswer.first]);
    adapter.queue.add((201, {
      'id': 9.0,
      'uploaded_by': 'lukas',
      'title': 'song.mp3',
      'artist': 'Kraftwerk',
      'duration_ms': 61000.0,
      'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
      'size': 1500000.0,
      'content_type': 'audio/mpeg',
      'uploaded_at': 1793974311.0,
    }));

    await openLibrary(tester, libraryBody: [libraryAnswer.first], uploadAdapter: adapter);
    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(find.text('song.mp3'), findsOneWidget);
    // The row shows what the answer says about the file it just stored. This artist
    // and length differ from the listed song, so the new row can be told apart.
    expect(find.text('Kraftwerk · 1:01'), findsOneWidget);
  });

  // The button stays disabled for the whole batch, and a file the server refused keeps
  // its message even when a later file of the same batch succeeds.
  testWidgets('the button stays disabled for the batch and a refused file keeps its message', (tester) async {
    final adapter = StubAdapter(200, [libraryAnswer.first]);
    adapter.queue.add((400, {'error': 'only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)'}));
    adapter.queue.add((201, {
      'id': 10.0,
      'uploaded_by': 'lukas',
      'title': 'second.mp3',
      'artist': '',
      'duration_ms': 0.0,
      'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
      'size': 1500000.0,
      'content_type': 'audio/mpeg',
      'uploaded_at': 1793974311.0,
    }));
    final gate = Completer<void>();
    adapter.wait = gate.future;

    await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      uploadAdapter: adapter,
      pickAudio: () async => [
        (name: 'notes.txt', bytes: Uint8List.fromList([1, 2, 3])),
        (name: 'second.mp3', bytes: Uint8List.fromList([4, 5, 6])),
      ],
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    // The first answer is held by the gate, so the second file has not been sent and the
    // button is still disabled.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Wird hochgeladen…')).onPressed, isNull);
    expect(find.textContaining('only audio files are accepted'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('notes.txt: only audio files are accepted'), findsOneWidget);
    expect(find.text('second.mp3'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Song hochladen')).onPressed, isNotNull);
  });

  testWidgets('a file the server refuses is not added', (tester) async {
    final adapter = StubAdapter(200, [libraryAnswer.first]);
    adapter.queue.add((400, {'error': 'only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)'}));

    await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      uploadAdapter: adapter,
      pickAudio: () async => [(name: 'notes.txt', bytes: Uint8List.fromList([1, 2, 3]))],
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('only audio files are accepted'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing);
  });

  // A picker that cannot answer is not a file the server refused, so there is no
  // file name to show; the message says what to do next and the button is usable
  // again.
  testWidgets('a picker that fails says what to do next', (tester) async {
    await openLibrary(tester, pickAudio: () async => throw Exception('no file picker in a test'));

    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(find.text('Die Dateien konnten nicht gelesen werden. Versuch es erneut.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Song hochladen')).onPressed, isNotNull);
  });

  // Cancelling the picker is not an error, so nothing is claimed about it. A second
  // test, because the screen keeps its message: the same State is reused when the
  // widget is pumped again, so this cannot be checked in the one above.
  testWidgets('cancelling the picker shows no error', (tester) async {
    await openLibrary(tester, libraryBody: [], pickAudio: () async => null);

    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('konnten nicht gelesen werden'), findsNothing);
    expect(find.textContaining('Bibliothek ist noch leer'), findsOneWidget);
  });

  // The navigation is the same list on both screens, so the library can be opened
  // from Home and Home can be reached again from the library.
  testWidgets('the navigation opens the library and leads back', (tester) async {
    tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final session = loggedIn();
    final dio = Dio()..httpClientAdapter = StubAdapter(200, {'id': 7.0, 'username': 'lukas'});
    // The page asks who the session belongs to, then the library; two adapters so
    // the test does not depend on which answer comes first.
    final libraryAdapter = StubAdapter(200, libraryAnswer);

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: buildRouter(
          AuthRepository(dio, session),
          UploadRepository(dio, session),
          LibraryRepository(Dio()..httpClientAdapter = libraryAdapter, session),
          PlaylistStore(),
          Player(session, (url, headers) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bibliothek'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsOneWidget);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });
}
