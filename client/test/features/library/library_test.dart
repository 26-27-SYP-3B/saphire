import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/utils/pick_audio.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';
import 'package:saphire_client/features/library/presentation/library_screen.dart';
import 'package:saphire_client/features/player/data/player.dart';
import 'package:saphire_client/features/playlists/data/playlist_store.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/stub_adapter.dart';

// The two orders must differ: by title "Alle" comes first, by the added date the
// newer song comes first.
const libraryAnswer = [
  {'id': 4.0, 'title': 'Kraftwerk - Technogal.mp3', 'uploaded_at': 300.0},
  {'id': 8.0, 'title': 'Alle Songs.mp3', 'uploaded_at': 100.0},
];

SessionStore loggedIn() =>
    SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

/// The library screen with a session, so the guard lets it open. Every answer a
/// test needs comes from the stub adapter: the list first, then the upload.
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

void main() {
  test('reads the library answer as songs', () async {
    final tracks = await LibraryRepository(
      Dio()..httpClientAdapter = StubAdapter(200, libraryAnswer),
      loggedIn(),
    ).list();

    expect(tracks.map((track) => track.title), ['Kraftwerk - Technogal.mp3', 'Alle Songs.mp3']);
  });

  // The answer has no artist field, so the row can only show what the name itself
  // says — and nothing where the name does not say it.
  test('the artist is the part of the name before the separator', () {
    expect(artistOf('Kraftwerk - Technogal.mp3'), 'Kraftwerk');
    expect(artistOf('Alle Songs.mp3'), '');
  });

  testWidgets('the library shows every song', (tester) async {
    await openLibrary(tester);

    expect(find.text('Kraftwerk - Technogal.mp3'), findsOneWidget);
    expect(find.text('Kraftwerk · –'), findsOneWidget);
    expect(find.text('Alle Songs.mp3'), findsOneWidget);
    expect(find.text('– · –'), findsOneWidget);
  });

  testWidgets('an empty library says so and offers an upload', (tester) async {
    await openLibrary(tester, libraryBody: []);

    expect(find.textContaining('Bibliothek ist noch leer'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Song hochladen'), findsOneWidget);
  });

  testWidgets('the search field only shows what matches', (tester) async {
    await openLibrary(tester);

    await tester.enterText(find.byType(TextField), 'kraftwerk');
    await tester.pumpAndSettle();

    expect(find.text('Kraftwerk - Technogal.mp3'), findsOneWidget);
    expect(find.text('Alle Songs.mp3'), findsNothing);
  });

  testWidgets('the sort selection orders the rows by what was picked', (tester) async {
    await openLibrary(tester);

    // Titel: what starts with A comes first.
    expect(
      tester.getTopLeft(find.text('Alle Songs.mp3')).dy,
      lessThan(tester.getTopLeft(find.text('Kraftwerk - Technogal.mp3')).dy),
    );

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sortieren: Hinzugefügt am'));
    await tester.pumpAndSettle();

    // Hinzugefügt am: the newer song comes first, which is the other order.
    expect(
      tester.getTopLeft(find.text('Alle Songs.mp3')).dy,
      greaterThan(tester.getTopLeft(find.text('Kraftwerk - Technogal.mp3')).dy),
    );
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
      find.descendant(of: find.byType(PlayerBar), matching: find.text('Kraftwerk - Technogal.mp3')),
      findsOneWidget,
    );
  });

  testWidgets('the context menu adds a song to the queue and to a playlist', (tester) async {
    final store = await openLibrary(tester, libraryBody: [libraryAnswer.first]);

    await openMenu(tester, 'Kraftwerk - Technogal.mp3');
    await tester.tap(find.text('Zur Warteschlange hinzufügen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Als nächstes: Kraftwerk'), findsOneWidget);

    await openMenu(tester, 'Kraftwerk - Technogal.mp3');
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
      'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
      'size': 1500000.0,
      'content_type': 'audio/mpeg',
      'uploaded_at': 1793974311.0,
    }));

    await openLibrary(tester, libraryBody: [libraryAnswer.first], uploadAdapter: adapter);
    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(find.text('song.mp3'), findsOneWidget);
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

  testWidgets('clicking Bibliothek in the navigation opens the library', (tester) async {
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
    expect(find.text('Kraftwerk - Technogal.mp3'), findsOneWidget);
  });
}
