import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/app/theme.dart';
import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/settings_store.dart';
import 'package:saphire_client/core/utils/pick_audio.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';
import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/library/presentation/library_screen.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/presentation/queue_panel.dart';
import 'package:saphire_client/features/playlists/presentation/playlists_screen.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';
import 'package:saphire_client/features/upload/domain/track.dart';
import 'package:saphire_client/shared/widgets/library_sidebar.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

// Three rows, so all three orders the page can be sorted by come out different:
// Titel gives Alle Songs, Bohne, Neutrone; Interpret gives Bohne, Neutrone, Alle
// Songs; Hinzugefügt am gives Neutrone, Alle Songs, Bohne. With two rows two of
// those orders would be the same, and a test could pass while the wrong branch
// decided it.
//
// The artist and the length are what the server read out of the file (api-docs.md,
// GET /api/music); the row with no length shows a dash instead of a guess.
const libraryAnswer = [
  {
    'id': 4.0,
    'title': 'Neutrone (Remix)',
    'artist': 'Kraftwerk',
    'album': 'Trans Europa Express',
    'genre': 'Elektronik',
    'year': 1977.0,
    'duration_ms': 215000.0,
    'waveform': [0.0, 64.0, 255.0],
    'uploaded_at': 300.0,
  },
  {
    'id': 8.0,
    'title': 'Alle Songs',
    'artist': 'Zukunft',
    'album': '',
    'genre': 'Pop',
    'year': 0.0,
    'duration_ms': 0.0,
    'uploaded_at': 200.0,
  },
  {
    'id': 9.0,
    'title': 'Bohne',
    'artist': 'Anna',
    'album': 'Gemüse',
    'genre': 'Pop',
    'year': 2024.0,
    'duration_ms': 121000.0,
    'uploaded_at': 100.0,
  },
];

// One playlist for the Playlists chip and the sidebar.
const playlistForLibrary = {
  'id': 1.0,
  'name': 'Favoriten',
  'created_at': 1794180269.0,
  'song_count': 2.0,
};

// What POST /api/queue answers for a fill from one song: that song at slot 1. A queue entry
// is only a reference to a library song, so the title here is the title the library row has,
// and a test that looks at the bar can only assert what this answer says — the page shows the
// title the queue gave it, not the one it read from GET /api/music.
List<Object> queueFor(int trackId, String title) => [
  {'position': 1.0, 'track_id': trackId * 1.0, 'title': title},
];

/// A playlist answer for the menu test. The id is what the create returns, so a test that
/// checks the follow-up call reads it from here rather than assuming one.
const createdPlaylist = {
  'id': 1.0,
  'name': 'Meine Playlist',
  'created_at': 1794180269.0,
  'song_count': 0.0,
};

/// The library page with a session, so the repositories send a token. The page is pumped on
/// its own here, so the router guard is not part of these tests; the navigation test below
/// covers the guard.
///
/// The page now works with the app's shared repositories and the shared queue and player, so
/// the test gets the wiring back and asserts what those were asked for. A page that only kept
/// its own lists could not be checked from the outside, and the player here needs no platform.
///
/// Two adapters, because the stub answers one fixed body or a queue of bodies: the list is
/// answered by `libraryAdapter` (or `libraryBody`), the upload by `uploadAdapter`. A test that
/// needs both a failing read and a failing upload gives both. The page reads the playlist names
/// with the library, so a test that does not look at the menu still needs that call to answer
/// something; the default is the empty list.
///
/// `settle` is off for the test that looks at the page while the request is still
/// open: the loading bar repeats its animation, so settling would never finish.
Future<Wiring> openLibrary(
  WidgetTester tester, {
  Object libraryBody = libraryAnswer,
  StubAdapter? libraryAdapter,
  StubAdapter? uploadAdapter,
  StubAdapter? playlists,
  StubAdapter? queues,
  PickAudio? pickAudio,
  SongPlayer? audio,
  SettingsStore? settings,
  LocalLibrary? localLibrary,
  Size size = const Size(1600, 1200),
  int? initialTrackId,
  bool settle = true,
}) async {
  // The test font draws every glyph as wide as the font size, so this page needs
  // more room than the default test window.
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final list = libraryAdapter ?? StubAdapter(200, libraryBody);
  // The page reads the playlist names with the library, so a test that does not look at the
  // menu still needs that call to answer something; the default is the empty list, because a
  // real Dio here would be a request to a server that is not there.
  final playlistAdapter = playlists ?? StubAdapter(200, <Object>[]);
  final wiring = Wiring(
    loggedIn(),
    libraryAdapter: list,
    playlistAdapter: playlistAdapter,
    queueAdapter: queues,
    audio: audio,
  );
  addTearDown(wiring.dispose);

  await tester.pumpWidget(
    // The app's own theme, so a test that looks at a color sees the color the app
    // really paints.
    MaterialApp(
      theme: buildTheme(),
      home: LibraryScreen(
        library: wiring.library,
        playlists: wiring.playlists,
        queues: wiring.queues,
        queue: wiring.queue,
        player: wiring.player,
        session: wiring.session,
        uploads: UploadRepository(
          Dio()..httpClientAdapter = uploadAdapter ?? list,
          wiring.session,
        ),
        pickAudio:
            pickAudio ??
            (() async => [
              (name: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3])),
            ]),
        settings: settings,
        localLibrary: localLibrary ?? LocalLibrary(),
        initialTrackId: initialTrackId,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();

  return wiring;
}

Future<void> openMenu(WidgetTester tester, String title) async {
  await tester.tap(find.byTooltip('Aktionen für $title'));
  await tester.pumpAndSettle();
}

// The sort is a row of chips, so the one that is picked is tapped directly.
Future<void> pickSort(WidgetTester tester, String key) async {
  await tester.tap(find.text(key));
  await tester.pumpAndSettle();
}

/// The filter panel is opened by its button; after a pick the label carries the count, so
/// this only works while no filter is set.
Future<void> openFilterPanel(WidgetTester tester) async {
  await tester.tap(find.text('Filter'));
  await tester.pumpAndSettle();
}

/// A filter value is drawn as a chip and, for an artist, again in a row, so a pick addresses
/// the chip by the category it belongs to rather than by the text it shows.
Future<void> pickFilter(
  WidgetTester tester,
  String category,
  String value,
) async {
  final chip = find.byKey(ValueKey('filter-$category-$value'));
  // The panel scrolls when it is taller than its box, so a category further down has to be
  // brought into view before it can be tapped.
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

/// The rows as the page shows them, top to bottom. A row can only be told apart by
/// the text it draws, so the titles are what the order is read from.
List<String> shownOrder(WidgetTester tester, List<String> titles) {
  final rows = [
    for (final title in titles) (title, tester.getTopLeft(find.text(title)).dy),
  ]..sort((a, b) => a.$2.compareTo(b.$2));

  return [for (final row in rows) row.$1];
}

// The row's own play icon, not the one the bar at the bottom has. Both are called
// 'Abspielen', so an unscoped finder here would find the bar's button as well.
Finder playIcon(WidgetTester tester) => find.descendant(
  of: find.byType(CustomScrollView),
  matching: find.byTooltip('Abspielen'),
);

void main() {
  test('reads the library answer as songs', () async {
    final tracks = await LibraryRepository(
      Dio()..httpClientAdapter = StubAdapter(200, libraryAnswer),
      loggedIn(),
    ).list();

    expect(tracks.map((track) => track.title), [
      'Neutrone (Remix)',
      'Alle Songs',
      'Bohne',
    ]);
    expect(tracks.first.artist, 'Kraftwerk');
    expect(tracks.first.album, 'Trans Europa Express');
    expect(tracks.first.genre, 'Elektronik');
    expect(tracks.first.year, 1977);
    expect(tracks.first.waveform, [0, 64, 255]);
    // A file that names none of them must not read as one.
    expect(tracks[1].album, '');
    expect(tracks[1].year, 0);
    // JSON numbers arrive as double on the web, so the length must survive the cast.
    expect(tracks.first.durationMs, 215000);
    expect(tracks[1].durationMs, 0);
    expect(tracks.last.durationMs, 121000);
  });

  // A row that is not an object cannot be half a song, so the answer is an error.
  test('a row that is not an object is an error', () async {
    await expectLater(
      LibraryRepository(
        Dio()..httpClientAdapter = StubAdapter(200, [4.0]),
        loggedIn(),
      ).list(),
      throwsA(isA<LibraryException>()),
    );
  });

  // The artist is what the tags said. A file without an artist tag says so; nothing is
  // guessed from the file name.
  test('the artist is the tag, or the unknown-artist placeholder', () {
    expect(
      artistOf(Track(id: 1, title: 'Neutrone (Remix)', artist: 'Kraftwerk')),
      'Kraftwerk',
    );
    expect(
      artistOf(Track(id: 2, title: 'Kraftwerk - Technogal.mp3')),
      'Unbekannter Künstler',
    );
    expect(
      artistOf(Track(id: 3, title: 'Alle Songs.mp3')),
      'Unbekannter Künstler',
    );
  });

  test('a length is shown as minutes and seconds, a file that cannot be measured as a dash', () {
    expect(durationOf(Track(id: 1, title: 'x', durationMs: 215000)), '3:35');
    expect(durationOf(Track(id: 2, title: 'x', durationMs: 61000)), '1:01');
    expect(durationOf(Track(id: 3, title: 'x')), '–');
  });

  testWidgets('the library shows every song with its artist and length', (
    tester,
  ) async {
    await openLibrary(tester);

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Kraftwerk'), findsOneWidget);
    expect(find.text('3:35'), findsOneWidget);
    expect(find.text('Alle Songs'), findsOneWidget);
    // A file the server could not measure shows a dash, not a guessed number.
    expect(find.text('Zukunft'), findsOneWidget);
    expect(find.text('–'), findsOneWidget);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('2:01'), findsOneWidget);

    // The page says what it shows, so the list can be read without counting it.
    expect(find.text('3 Songs'), findsOneWidget);
  });

  testWidgets('an empty library says so and offers an upload', (tester) async {
    await openLibrary(tester, libraryBody: []);

    expect(find.textContaining('Bibliothek ist noch leer'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Song hochladen'), findsOneWidget);
  });

  // Only [] means empty. An answer that is not the documented list is an error the
  // user is told about, not a library that looks empty.
  testWidgets('an answer that is not the documented list shows an error', (
    tester,
  ) async {
    await openLibrary(tester, libraryBody: {'id': 4.0});

    expect(
      find.text('Die Antwort des Servers konnte nicht gelesen werden.'),
      findsOneWidget,
    );
    expect(find.textContaining('Bibliothek ist noch leer'), findsNothing);
  });

  // A page that got an error says what happened and offers the one thing that can
  // still work: reading the list again. Showing "the library is empty" here would be
  // the page claiming something about an answer it never received.
  testWidgets('a failed read says what happened and can be started again', (
    tester,
  ) async {
    final adapter = StubAdapter(401, {
      'error': 'session is not valid or expired',
    });

    await openLibrary(tester, libraryAdapter: adapter);

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(find.textContaining('Bibliothek ist noch leer'), findsNothing);

    // The next answer is the documented list, so the retry has something to show.
    adapter.statusCode = 200;
    adapter.body = libraryAnswer;

    await tester.tap(find.text('Erneut versuchen'));
    await tester.pumpAndSettle();

    expect(find.text('Erneut versuchen'), findsNothing);
    expect(find.text('Neutrone (Remix)'), findsOneWidget);
  });

  // A message that is not about a read must not offer the retry that belongs to one.
  // Here the read failed and a file was refused afterwards, so the message names that
  // file and nothing would be fixed by reading the list again.
  testWidgets('the retry only belongs to a failed read', (tester) async {
    await openLibrary(
      tester,
      libraryAdapter: StubAdapter(401, {
        'error': 'session is not valid or expired',
      }),
      uploadAdapter: StubAdapter(400, {
        'error': 'only audio files are accepted',
      }),
    );

    expect(find.text('Erneut versuchen'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('only audio files are accepted'),
      findsOneWidget,
    );
    expect(find.text('Erneut versuchen'), findsNothing);
  });

  // While the list is still on its way the page says so, instead of claiming the
  // library is empty — that is what a slow server looked like before.
  testWidgets('the page says what it is doing while the list is on its way', (
    tester,
  ) async {
    final adapter = StubAdapter(200, libraryAnswer);
    final gate = Completer<void>();
    adapter.wait = gate.future;

    await openLibrary(tester, libraryAdapter: adapter, settle: false);
    await tester.pump();

    expect(find.text('Songs werden geladen.'), findsOneWidget);
    expect(find.textContaining('Bibliothek ist noch leer'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Songs werden geladen.'), findsNothing);
    expect(find.text('Neutrone (Remix)'), findsOneWidget);
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

  testWidgets('the sort selection orders the rows by what was picked', (
    tester,
  ) async {
    await openLibrary(tester);

    // Titel, the default: what starts with A comes first.
    const titles = ['Alle Songs', 'Bohne', 'Neutrone (Remix)'];
    expect(shownOrder(tester, titles), titles);

    await pickSort(tester, 'Interpret');

    // Interpret: the artists decide the order, so this is a different order than by
    // title — the rows are the same rows, only moved.
    expect(shownOrder(tester, titles), [
      'Bohne',
      'Neutrone (Remix)',
      'Alle Songs',
    ]);

    await pickSort(tester, 'Hinzugefügt am');

    // Hinzugefügt am: the newer song comes first, which is a different order than
    // either of the other two, so this branch is really the one that decided it.
    expect(shownOrder(tester, titles), [
      'Neutrone (Remix)',
      'Alle Songs',
      'Bohne',
    ]);
  });

  // The comparison is case-insensitive, so a name that starts with a small letter comes
  // before one that starts with a capital. With the code points alone the capital would
  // win, so both orders here are only what they claim to be if case is ignored — and the
  // two keys answer differently, so the test shows which key decided.
  testWidgets('the sort does not care about case', (tester) async {
    await openLibrary(
      tester,
      libraryBody: [
        {
          'id': 1.0,
          'title': 'Zeh',
          'artist': 'ahn',
          'duration_ms': 0.0,
          'uploaded_at': 1.0,
        },
        {
          'id': 2.0,
          'title': 'qhn',
          'artist': 'Zeta',
          'duration_ms': 0.0,
          'uploaded_at': 2.0,
        },
      ],
    );

    // Titel: 'qhn' before 'Zeh'.
    expect(shownOrder(tester, ['Zeh', 'qhn']), ['qhn', 'Zeh']);

    await pickSort(tester, 'Interpret');

    // Interpret: 'ahn' before 'Zeta', the other order than the names gave.
    expect(shownOrder(tester, ['Zeh', 'qhn']), ['Zeh', 'qhn']);
  });

  // What the sort key cannot decide is decided by the id, so the same rows keep the same
  // order on every rebuild. Here the titles are the same when case is ignored and the
  // artists and dates are equal, so only the id can tell them apart: ascending for the
  // names, descending for the date, which is the direction that key already reads in. The
  // ids are the other way round than the capitals, so a comparison that did care about
  // case would answer differently.
  testWidgets('rows the sort key cannot tell apart are ordered by id', (
    tester,
  ) async {
    await openLibrary(
      tester,
      libraryBody: [
        {
          'id': 8.0,
          'title': 'Gleich',
          'artist': 'Zukunft',
          'duration_ms': 0.0,
          'uploaded_at': 5.0,
        },
        {
          'id': 4.0,
          'title': 'gleich',
          'artist': 'Zukunft',
          'duration_ms': 0.0,
          'uploaded_at': 5.0,
        },
      ],
    );

    expect(shownOrder(tester, ['Gleich', 'gleich']), ['gleich', 'Gleich']);

    await pickSort(tester, 'Hinzugefügt am');
    expect(shownOrder(tester, ['Gleich', 'gleich']), ['Gleich', 'gleich']);
  });

  // Opening a row is not a play of its own: it fills the shared queue with that one song and
  // asks the shared player for the current entry, so the bar shows the same song the queue
  // page would. What the test can read is what the page sent and what the player was asked to
  // open — the title in the bar is the one the queue answer carries.
  testWidgets('playing a song fills the queue with it and opens that song', (
    tester,
  ) async {
    final audio = FakePlayer();
    final queues = StubAdapter(200, queueFor(4, 'Neutrone (Remix)'));
    final wiring = await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      queues: queues,
      audio: audio,
    );

    await tester.tap(playIcon(tester));
    await tester.pumpAndSettle();

    expect(queues.lastOptions?.data, {'source': 'track', 'source_id': 4});
    expect(audio.opened, ['$apiBaseUrl/api/music/4']);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('Neutrone (Remix)'),
      ),
      findsOneWidget,
    );
    expect(wiring.queue.current?.trackId, 4);
  });

  // The row itself can be tapped, so playing a song does not need the small icon.
  testWidgets('clicking the row plays the song', (tester) async {
    final audio = FakePlayer();
    final queues = StubAdapter(200, queueFor(8, 'Alle Songs'));
    await openLibrary(
      tester,
      libraryBody: [libraryAnswer[1]],
      queues: queues,
      audio: audio,
    );

    await tester.tap(find.text('Alle Songs'));
    await tester.pumpAndSettle();

    expect(queues.lastOptions?.data, {'source': 'track', 'source_id': 8});
    expect(audio.opened, ['$apiBaseUrl/api/music/8']);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('Alle Songs'),
      ),
      findsOneWidget,
    );
  });

  // The row of the song that is current in the queue is marked, so the page and the bar agree
  // on what is current. The marker is the row's own box, so the test reads it there. The theme
  // maps fieldBackground and accent to the colors the row uses, so the constants here are the
  // colors the app paints.
  testWidgets('the row of the song that is playing is marked', (tester) async {
    final audio = FakePlayer();
    final wiring = await openLibrary(
      tester,
      audio: audio,
      queues: StubAdapter(200, queueFor(8, 'Alle Songs')),
    );

    // The bar at the bottom shows the same title once a song is playing, so a row is
    // looked for inside the list rather than anywhere on the screen.
    BoxDecoration decorationOf(String title) {
      final row = tester.widget<Container>(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.ancestor(
            of: find.text(title),
            matching: find.byType(Container),
          ),
        ),
      );
      return row.decoration! as BoxDecoration;
    }

    // Nothing is playing yet, so no row is marked.
    expect(decorationOf('Alle Songs').color, isNull);

    await tester.tap(find.text('Alle Songs'));
    await tester.pumpAndSettle();

    expect(decorationOf('Alle Songs').color, fieldBackground);
    // The left edge is what marks the row, so it is read as the Border it is.
    expect((decorationOf('Alle Songs').border! as Border).left.color, accent);

    // A row that is not the current one stays unmarked.
    expect(decorationOf('Bohne').color, isNull);
    // The page and the bar name the same song.
    expect(wiring.queue.current?.trackId, 8);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('Alle Songs'),
      ),
      findsOneWidget,
    );
  });

  // A song that cannot be opened is not a JSON answer from the server, so the message is the
  // exception's own text, shown on the page that made the call. The song never opened, so it
  // must not stay current and the bar must not name it as if it were playing.
  testWidgets(
    'a song the player cannot start is named by the page, not by the bar',
    (tester) async {
      final audio = FakePlayer();
      audio.openError = 'das Audioobjekt ist geschlossen';
      final wiring = await openLibrary(
        tester,
        libraryBody: [libraryAnswer.first],
        queues: StubAdapter(200, queueFor(4, 'Neutrone (Remix)')),
        audio: audio,
      );

      await tester.tap(playIcon(tester));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('das Audioobjekt ist geschlossen'),
        findsOneWidget,
      );
      expect(wiring.queue.current, isNull);
      expect(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Nichts wird abgespielt'),
        ),
        findsOneWidget,
      );
    },
  );

  // Adding to the queue is a call, not a play: nothing becomes current, so the bar still names
  // no song. The menu's first entry creates the playlist it names when the page has none, and
  // the id the follow-up call uses is the one the answer carried.
  testWidgets('the context menu adds a song to the queue and to a playlist', (
    tester,
  ) async {
    final playlistAdapter = StubAdapter(200, <Object>[]);
    // Answers in the order the page calls them: the list (nothing yet, so the menu can only
    // offer the first one), the create, then the song.
    playlistAdapter.queue.addAll([
      (200, <Object>[]),
      (201, createdPlaylist),
      (201, {'position': 1.0, 'track_id': 4.0, 'title': 'Neutrone (Remix)'}),
    ]);
    final queueAdapter = StubAdapter(200, {
      'position': 1.0,
      'track_id': 4.0,
      'title': 'Neutrone (Remix)',
    });

    final wiring = await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      playlists: playlistAdapter,
      queues: queueAdapter,
    );

    await openMenu(tester, 'Neutrone (Remix)');
    await tester.tap(find.text('Zur Warteschlange hinzufügen'));
    await tester.pumpAndSettle();

    expect(queueAdapter.lastOptions?.data, {'track_id': 4});
    // The mirror takes the row the server answered with; adding does not make it current.
    expect(wiring.queue.entries.map((entry) => entry.trackId), [4]);
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('Nichts wird abgespielt'),
      ),
      findsOneWidget,
    );

    await openMenu(tester, 'Neutrone (Remix)');
    await tester.tap(find.text('Zur neuen Playlist „Meine Playlist“'));
    await tester.pumpAndSettle();

    // The list, the create, and the song at the id the create answered with — not an id the
    // page made up.
    final calls = playlistAdapter.requests;
    expect(calls.map((request) => request.uri.path), [
      '/api/playlists',
      '/api/playlists',
      '/api/playlists/1/songs',
    ]);
    expect(calls[1].data, {'name': 'Meine Playlist'});
    expect(calls[2].data, {'track_id': 4});
  });

  testWidgets('an uploaded song is added to the library', (tester) async {
    final adapter = StubAdapter(200, [libraryAnswer.first]);
    adapter.queue.add((
      201,
      {
        'id': 9.0,
        'uploaded_by': 'lukas',
        'title': 'song.mp3',
        // An artist and a length that differ from the listed song, so the row that came
        // from this answer can be told apart from the one that came from the list.
        'artist': 'Neu',
        'duration_ms': 61000.0,
        'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
        'size': 1500000.0,
        'content_type': 'audio/mpeg',
        'uploaded_at': 1793974311.0,
      },
    ));

    await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      uploadAdapter: adapter,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(find.text('song.mp3'), findsOneWidget);
    // The row shows what the answer says about the file it just stored. This artist
    // and length differ from the listed song, so the new row can be told apart.
    expect(find.text('Neu'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
  });

  // The button stays disabled for the whole batch, and a file the server refused keeps
  // its message even when a later file of the same batch succeeds.
  testWidgets(
    'the button stays disabled for the batch and a refused file keeps its message',
    (tester) async {
      final adapter = StubAdapter(200, [libraryAnswer.first]);
      adapter.queue.add((
        400,
        {
          'error': 'only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)',
        },
      ));
      adapter.queue.add((
        201,
        {
          'id': 10.0,
          'uploaded_by': 'lukas',
          'title': 'second.mp3',
          'artist': '',
          'duration_ms': 0.0,
          'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
          'size': 1500000.0,
          'content_type': 'audio/mpeg',
          'uploaded_at': 1793974311.0,
        },
      ));
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
      // button is still disabled. The button is taken by type, so the label is checked as
      // something the page chose rather than as the name the finder was given.
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect((button.child as Text).data, 'Wird hochgeladen…');
      expect(button.onPressed, isNull);
      expect(
        find.textContaining('only audio files are accepted'),
        findsNothing,
      );

      gate.complete();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('notes.txt: only audio files are accepted'),
        findsOneWidget,
      );
      expect(find.text('second.mp3'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Song hochladen'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  // A file the server refuses is not added, so there is nothing to show for it but its message.
  testWidgets('a file the server refuses is not added', (tester) async {
    final adapter = StubAdapter(200, [libraryAnswer.first]);
    adapter.queue.add((
      400,
      {
        'error': 'only audio files are accepted (mp3, wav, m4a, ogg, opus, flac, aac)',
      },
    ));

    await openLibrary(
      tester,
      libraryBody: [libraryAnswer.first],
      uploadAdapter: adapter,
      pickAudio: () async => [
        (name: 'notes.txt', bytes: Uint8List.fromList([1, 2, 3])),
      ],
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('only audio files are accepted'),
      findsOneWidget,
    );
    expect(find.text('notes.txt'), findsNothing);
  });

  // A picker that cannot answer is not a file the server refused, so there is no
  // file name to show; the message says what to do next and the button is usable
  // again.
  testWidgets('a picker that fails says what to do next', (tester) async {
    await openLibrary(
      tester,
      pickAudio: () async => throw Exception('no file picker in a test'),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Song hochladen'));
    await tester.pumpAndSettle();

    expect(
      find.text('Die Dateien konnten nicht gelesen werden. Versuch es erneut.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Song hochladen'),
          )
          .onPressed,
      isNotNull,
    );
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

  // The local songs are part of the same list, so a search does not have to look in two
  // places and a user does not have to know which library a song is in.
  testWidgets('local songs and server songs share the list', (tester) async {
    final local = LocalLibrary();
    local.add(name: 'lokal.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    await openLibrary(tester, localLibrary: local);

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('lokal.mp3'), findsOneWidget);
    expect(find.text('Unbekannter Künstler'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'lokal');
    await tester.pumpAndSettle();

    expect(find.text('lokal.mp3'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
  });

  // Local mode has no server and no session: the songs on this device are all the page
  // needs, and uploading is not something it could offer.
  testWidgets(
    'a local library opens without a session and shows the songs on this device',
    (tester) async {
      final local = LocalLibrary();
      local.add(
        name: 'lokal.mp3',
        bytes: Uint8List.fromList([0x49, 0x44, 0x33]),
      );
      final adapter = StubAdapter(200, libraryAnswer);

      await openLibrary(
        tester,
        libraryAdapter: adapter,
        settings: SettingsStore()..save(localMode: true),
        localLibrary: local,
      );

      expect(find.text('lokal.mp3'), findsOneWidget);
      expect(find.text('Unbekannter Künstler'), findsOneWidget);
      // Not one call went to the server, so the page did not quietly read a library it
      // cannot use.
      expect(adapter.requests, isEmpty);
      expect(find.text('Neutrone (Remix)'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Song hochladen'), findsNothing);
    },
  );

  testWidgets('a local row plays the file on this device', (tester) async {
    final audio = FakePlayer();
    final local = LocalLibrary();
    local.add(name: 'lokal.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    await openLibrary(
      tester,
      settings: SettingsStore()..save(localMode: true),
      localLibrary: local,
      audio: audio,
    );

    await tester.tap(playIcon(tester));
    await tester.pumpAndSettle();

    // No server and no token: the song is opened from the bytes the pick gave.
    expect(audio.opened.single, startsWith('data:audio/mpeg'));
    expect(audio.played, hasLength(1));
    // The bar names the same song, so the page does not say two things at once.
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('lokal.mp3'),
      ),
      findsOneWidget,
    );
    // A file on this device can be queued and put into a local playlist, so it has its own
    // actions menu now.
    expect(find.byTooltip('Aktionen für lokal.mp3'), findsOneWidget);

    // The bar's play button continues the paused local song instead of clearing it.
    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byTooltip('Pause'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.byTooltip('Abspielen'),
      ),
    );
    await tester.pumpAndSettle();

    expect(audio.opened, hasLength(1));
    expect(audio.played, hasLength(2));
    expect(
      find.descendant(
        of: find.byType(PlayerBar),
        matching: find.text('lokal.mp3'),
      ),
      findsOneWidget,
    );
  });

  // A shared link names a song, not a page: opening it is the same as tapping that row, so the
  // song is in the queue and the player has opened its stream.
  testWidgets('a link opens the library at the song it names', (tester) async {
    final audio = FakePlayer();
    final wiring = await openLibrary(
      tester,
      audio: audio,
      queues: StubAdapter(200, queueFor(9, 'Bohne')),
      initialTrackId: 9,
    );

    expect(wiring.queue.current?.trackId, 9);
    expect(audio.opened, ['$apiBaseUrl/api/music/9']);
    // The row and the bar at the bottom both name the song that is now playing.
    expect(find.text('Bohne'), findsWidgets);
  });

  // Without a server there is no library the link could name, so it says so instead of quietly
  // opening the device pages.
  testWidgets('a link in local mode says the song is not in the library', (
    tester,
  ) async {
    final audio = FakePlayer();
    await openLibrary(
      tester,
      audio: audio,
      settings: SettingsStore()..save(localMode: true),
      initialTrackId: 8,
    );

    expect(
      find.text('Das verlinkte Lied ist nicht in der Bibliothek.'),
      findsOneWidget,
    );
    expect(audio.opened, isEmpty);
  });

  // A link to a song that is no longer in the library must not open a different one; it says
  // what is missing and leaves the page as it is.
  testWidgets('a link to a missing song says so and plays nothing', (
    tester,
  ) async {
    final audio = FakePlayer();
    await openLibrary(tester, audio: audio, initialTrackId: 999);

    expect(
      find.text('Das verlinkte Lied ist nicht in der Bibliothek.'),
      findsOneWidget,
    );
    expect(audio.opened, isEmpty);
  });

  // Every page draws the same items from nav_bar.dart, so a page can only be opened where
  // buildRouter has a route for it. The library has one, so the item on Home opens this page
  // and the bar on this page leads back; that round trip is why the navigation is shared
  // rather than drawn per page.
  testWidgets('the navigation opens the library and leads back', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1600, 1200)
      ..devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final wiring = Wiring(
      loggedIn(),
      libraryAdapter: StubAdapter(200, libraryAnswer),
      playlistAdapter: StubAdapter(200, <Object>[]),
      queueAdapter: StubAdapter(200, <Object>[]),
    );
    addTearDown(wiring.dispose);

    // The guard only reads the session, but Home asks who that session belongs to and drops it
    // when the answer is not there — so the test answers that call instead of sending it to a
    // network that is not there. Without this the page would be on the login, not on Home.
    final auth = AuthRepository(
      Dio()
        ..httpClientAdapter = StubAdapter(200, {
          'id': 7.0,
          'username': 'lukas',
        }),
      wiring.session,
    );

    final router = buildRouter(
      auth: auth,
      uploads: UploadRepository(Dio(), wiring.session),
      library: wiring.library,
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: wiring.session,
      settings: withServer(),
      dio: Dio(),
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('open-library')));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    // The page shows the songs its adapter answered, so opening it through the navigation is
    // the same page as opening it directly.
    expect(find.text('Neutrone (Remix)'), findsOneWidget);

    // Every page with the sidebar leads on from every other one.
    await tester.tap(
      find.descendant(
        of: find.byType(LibrarySidebar),
        matching: find.text('Playlists'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistsScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsOneWidget);

    // The panel is the column on the right, so the navigation stays reachable; closing it gives the
    // page back.
    await tester.tap(find.byTooltip('Warteschlange schließen'));
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);

    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // The filter is read from the songs, so it can only offer what the list can show. A picked
  // value narrows the list at once and says how many songs are left.
  testWidgets('the filter narrows the list and shows the hit count', (
    tester,
  ) async {
    await openLibrary(tester);
    await openFilterPanel(tester);

    expect(
      find.byKey(const ValueKey('filter-Interpret-Kraftwerk')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('filter-Album-Gemüse')), findsOneWidget);
    expect(find.byKey(const ValueKey('filter-Genre-Pop')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('filter-Erscheinungsjahr-2024')),
      findsOneWidget,
    );

    await pickFilter(tester, 'Interpret', 'Kraftwerk');

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Bohne'), findsNothing);
    expect(find.text('Alle Songs'), findsNothing);
    expect(find.text('1 von 3 Songs passen zu den Filtern'), findsOneWidget);
    // The pick stays visible above the list, so the narrowed list says why it is narrow.
    expect(find.text('Interpret: Kraftwerk'), findsOneWidget);
  });

  // Two values of one category are an "or"; a second category is an "and" on top.
  testWidgets(
    'values of a category are combined with or, categories with and',
    (tester) async {
      await openLibrary(tester);
      await openFilterPanel(tester);

      await pickFilter(tester, 'Interpret', 'Kraftwerk');
      await pickFilter(tester, 'Interpret', 'Anna');

      expect(find.text('Neutrone (Remix)'), findsOneWidget);
      expect(find.text('Bohne'), findsOneWidget);
      expect(find.text('Alle Songs'), findsNothing);
      expect(find.text('2 von 3 Songs passen zu den Filtern'), findsOneWidget);

      // Kraftwerk's genre is Elektronik, Anna's is Pop, so the genre category is an "and" on
      // top of the artist "or": only Anna's song has both her and Pop.
      await pickFilter(tester, 'Genre', 'Pop');
      expect(find.text('Bohne'), findsOneWidget);
      expect(find.text('Neutrone (Remix)'), findsNothing);

      // The second genre is the "or" that lets the other artist through again.
      await pickFilter(tester, 'Genre', 'Elektronik');
      expect(find.text('Neutrone (Remix)'), findsOneWidget);
      expect(find.text('Bohne'), findsOneWidget);
    },
  );

  // A missing value is a value: a song without an album is not hidden from every album
  // filter, it is under "Unbekannt". A song on this device has no tags, so it is there too.
  testWidgets('a song without metadata is filtered as Unbekannt', (
    tester,
  ) async {
    final local = LocalLibrary()..add(name: 'Lokales Lied.mp3');
    await openLibrary(tester, localLibrary: local);
    await openFilterPanel(tester);

    await pickFilter(tester, 'Album', 'Unbekannt');

    expect(find.text('Alle Songs'), findsOneWidget);
    expect(find.text('Lokales Lied.mp3'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
    expect(find.text('Bohne'), findsNothing);
  });

  testWidgets('the year is a filter value like any other', (tester) async {
    await openLibrary(tester);
    await openFilterPanel(tester);

    await pickFilter(tester, 'Erscheinungsjahr', '2024');

    expect(find.text('Bohne'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
    expect(find.text('Alle Songs'), findsNothing);
  });

  // Search, filter and sort apply together: the filter decides which songs are in the list,
  // the search narrows that list, and the sort orders what is left.
  testWidgets(
    'search and filter apply together, and the reset brings the library back',
    (tester) async {
      await openLibrary(tester);
      await openFilterPanel(tester);
      await pickFilter(tester, 'Interpret', 'Kraftwerk');

      // Close the panel so the chip row is the only place with the reset button.
      await tester.tap(find.text('Filter (1)'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'bohne');
      await tester.pumpAndSettle();

      expect(find.text('Keine Songs gefunden.'), findsOneWidget);
      expect(
        find.text('0 von 3 Songs passen zu Suche und Filter'),
        findsOneWidget,
      );

      // The empty state offers the reset, so the filter can be taken off without going back to
      // the panel. The search stays, because it is not a filter.
      await tester.tap(
        find.widgetWithText(TextButton, 'Filter zurücksetzen').last,
      );
      await tester.pumpAndSettle();

      expect(find.text('Bohne'), findsOneWidget);
      expect(find.text('Neutrone (Remix)'), findsNothing);
      expect(find.text('1 von 3 Songs passen zur Suche'), findsOneWidget);
      expect(find.textContaining('Filter:'), findsNothing);
    },
  );

  // One chip can be taken off on its own, and the last reset takes all of them off.
  testWidgets('a chip removes one filter, the reset removes all', (
    tester,
  ) async {
    await openLibrary(tester);
    await openFilterPanel(tester);
    await pickFilter(tester, 'Interpret', 'Kraftwerk');
    await pickFilter(tester, 'Interpret', 'Anna');
    await tester.tap(find.text('Filter (2)'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Filter Interpret: Anna entfernen'));
    await tester.pumpAndSettle();

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Bohne'), findsNothing);
    expect(find.text('Interpret: Anna'), findsNothing);
    expect(find.text('Interpret: Kraftwerk'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Filter zurücksetzen'));
    await tester.pumpAndSettle();

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Bohne'), findsOneWidget);
    expect(find.text('Alle Songs'), findsOneWidget);
    expect(find.text('Interpret: Kraftwerk'), findsNothing);
    expect(find.text('3 Songs'), findsOneWidget);
  });

  // The chips are views, not another filter on the same page: Lokal keeps the device songs,
  // and tapping it again brings the server songs back.
  testWidgets('the Lokal chip shows only the songs on this device', (
    tester,
  ) async {
    final local = LocalLibrary();
    local.add(name: 'lokal.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    await openLibrary(tester, localLibrary: local);

    // The sidebar has a Lokal chip too, so the page's chip is the last one.
    await tester.tap(find.byKey(const ValueKey('view-local')));
    await tester.pumpAndSettle();

    expect(find.text('lokal.mp3'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
    expect(find.text('1 Songs'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('view-local')));
    await tester.pumpAndSettle();

    expect(find.text('lokal.mp3'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsOneWidget);
  });

  // Playlists is a chip of the library, not a separate page: it lists what the caller owns
  // with its cover and count.
  testWidgets('the Playlists chip lists the playlists', (tester) async {
    await openLibrary(
      tester,
      playlists: StubAdapter(200, <Object>[playlistForLibrary]),
    );

    await tester.tap(find.byKey(const ValueKey('view-playlists')));
    await tester.pumpAndSettle();

    expect(find.text('Favoriten'), findsWidgets);
    expect(find.text('Playlist · 2 Songs'), findsWidgets);
    expect(find.text('1 Playlists'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
  });

  // The grid is the same rows with another shape, so a song is still playable there.
  testWidgets('the grid shows the songs as cards', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openLibrary(
      tester,
      audio: audio,
      queues: StubAdapter(200, queueFor(9, 'Bohne')),
    );

    await tester.tap(find.byTooltip('Raster'));
    await tester.pumpAndSettle();

    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Bohne'), findsOneWidget);

    await tester.tap(find.text('Bohne'));
    await tester.pumpAndSettle();
    expect(audio.played, isNotEmpty);
  });

  // A phone in landscape is wide enough for the inline panel by width, but not by height: the
  // header would overflow the page, so it gets the same overlay as a portrait phone.
  testWidgets('a wide but short window gets the filter overlay', (
    tester,
  ) async {
    await openLibrary(tester, size: const Size(844, 390));
    await openFilterPanel(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Anwenden'), findsOneWidget);
  });

  // A window that clears the panel's own height can still be too short: the player bar and the
  // header sit above it, and at 700 px the inline panel clipped its reset button. Such a window
  // gets the overlay too.
  testWidgets(
    'a wide window without room for the inline panel gets the overlay',
    (tester) async {
      await openLibrary(tester, size: const Size(760, 700));
      await openFilterPanel(tester);

      expect(find.byType(BottomSheet), findsOneWidget);
    },
  );

  // A large text scale makes the panel and the chip row taller, so the window needs the same
  // room it would need at a larger size; otherwise the inline panel gets clipped.
  testWidgets('a large text scale gets the filter overlay', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await openLibrary(tester, size: const Size(760, 860));
    await openFilterPanel(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
  });

  // On a phone the filter is an overlay with an Apply button, because the list behind it is
  // not visible while the overlay is open.
  testWidgets('on a phone the filter is applied from an overlay', (
    tester,
  ) async {
    await openLibrary(tester, size: const Size(360, 740));
    await openFilterPanel(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Anwenden'), findsOneWidget);

    await pickFilter(tester, 'Interpret', 'Anna');
    await tester.tap(find.widgetWithText(FilledButton, 'Anwenden'));
    await tester.pumpAndSettle();

    expect(find.text('Bohne'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);
    expect(find.text('Interpret: Anna'), findsOneWidget);
    expect(find.text('1 von 3 Songs passen zu den Filtern'), findsOneWidget);
  });

  // Closing the phone overlay without "Anwenden" must not apply the picks that were only a draft.
  testWidgets('dismissing the phone filter without Apply keeps the library', (
    tester,
  ) async {
    await openLibrary(tester, size: const Size(360, 740));
    await openFilterPanel(tester);

    await pickFilter(tester, 'Interpret', 'Anna');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('3 Songs'), findsOneWidget);
    expect(find.text('Interpret: Anna'), findsNothing);
    expect(find.text('Neutrone (Remix)'), findsOneWidget);
    expect(find.text('Bohne'), findsOneWidget);
  });
}
