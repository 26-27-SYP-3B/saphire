import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/app/theme.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/storage/settings_store.dart';
import 'package:saphire_client/core/utils/pick_image.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/playlists/data/cover_store.dart';
import 'package:saphire_client/features/playlists/data/playlist_repository.dart';
import 'package:saphire_client/features/player/presentation/queue_sheet.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

const playlistAnswer = {
  'id': 1.0,
  'name': 'Favoriten',
  'created_at': 1794180269.0,
  'song_count': 0.0,
};

// Numbers as they arrive on the web: as doubles, so the model reads them through num.
const detailAnswer = {
  'id': 1.0,
  'name': 'Favoriten',
  'created_at': 1794180269.0,
  'song_count': 2.0,
  'songs': [
    {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
    {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
  ],
};

// What the queue answers after being filled from this playlist: the same two songs, in
// the playlist order. Nothing in this shape says where they came from.
const queueAnswer = [
  {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
  {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
];

/// Opens the app on the Playlists page with a valid session, so the guard lets a test
/// reach it the way a logged-in user does. The page needs the shared queue, so the test
/// gets the wiring back and can look at what the page put into it.
Future<Wiring> openPlaylists(
  WidgetTester tester, {
  StubAdapter? playlists,
  StubAdapter? queues,
  StubAdapter? library,
  CoverStore? covers,
  PickImage? pickImage,
  Size size = const Size(1600, 1200),
}) async {
  // The two-pane layout needs more room than the default test window.
  tester.view..physicalSize = size..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final session = loggedIn();
  final wiring = Wiring(session, playlistAdapter: playlists, queueAdapter: queues, libraryAdapter: library);
  addTearDown(wiring.dispose);

  // The guard only reads the session, so a repository that is never called is enough.
  final auth = AuthRepository(Dio(), session);
  final router = buildRouter(
    auth: auth,
    uploads: UploadRepository(Dio(), session),
    library: wiring.library,
    playlists: wiring.playlists,
    queues: wiring.queues,
    queue: wiring.queue,
    player: wiring.player,
    session: session,
    settings: withServer(),
    covers: covers,
    // A test does not tap the real picker; the one it passes answers instead.
    pickImage: pickImage ?? () async => null,
    dio: Dio(),
  );

  router.go('/playlists');
  // The real theme, because its button sizes are what a Row has to live with.
  await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
  await tester.pumpAndSettle();

  return wiring;
}

/// Opens the app in local mode, the way a user without an account does. No adapter is
/// needed: none of these pages may call the server in this mode.
Future<Wiring> openLocalPlaylists(WidgetTester tester, LocalLibrary local) async {
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final session = SessionStore();
  final wiring = Wiring(session);
  addTearDown(wiring.dispose);

  final router = buildRouter(
    auth: AuthRepository(Dio(), session),
    uploads: UploadRepository(Dio(), session),
    library: wiring.library,
    playlists: wiring.playlists,
    queues: wiring.queues,
    queue: wiring.queue,
    player: wiring.player,
    session: session,
    settings: SettingsStore()..save(localMode: true),
    localLibrary: local,
    dio: Dio(),
  );

  router.go('/playlists');
  await tester.pumpWidget(MaterialApp.router(theme: buildTheme(), routerConfig: router));
  await tester.pumpAndSettle();

  return wiring;
}

void main() {
  test('reads a playlist answer', () async {
    final repository = PlaylistRepository(Dio()..httpClientAdapter = StubAdapter(201, playlistAnswer), loggedIn());

    final playlist = await repository.create('Favoriten');

    expect(playlist.id, 1);
    expect(playlist.name, 'Favoriten');
    expect(playlist.createdAt, 1794180269);
    expect(playlist.songCount, 0);
  });

  test('reads one playlist with its songs in position order', () async {
    final repository = PlaylistRepository(Dio()..httpClientAdapter = StubAdapter(200, detailAnswer), loggedIn());

    final detail = await repository.get(1);

    expect(detail.songs.map((song) => song.position), [1, 2]);
    expect(detail.songs.first.trackId, 8);
    // The title comes from the library row, not from the playlist.
    expect(detail.songs.first.title, 'Technogal.mp3');
  });

  // An empty playlist answers [], never null.
  test('an empty playlist is an empty list, not a missing value', () async {
    final repository = PlaylistRepository(
      Dio()..httpClientAdapter = StubAdapter(200, {...playlistAnswer, 'songs': <Object>[]}),
      loggedIn(),
    );
    expect((await repository.get(1)).songs, isEmpty);

    final list = await PlaylistRepository(Dio()..httpClientAdapter = StubAdapter(200, <Object>[]), loggedIn()).list();
    expect(list, isEmpty);
  });

  test('the calls go to the documented paths with the session token', () async {
    final adapter = StubAdapter(201, playlistAnswer);
    final repository = PlaylistRepository(Dio()..httpClientAdapter = adapter, loggedIn());

    await repository.create('Favoriten');
    expect(adapter.lastOptions?.method, 'POST');
    expect(adapter.lastOptions?.uri.path, '/api/playlists');
    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer ${'a' * 64}');

    // The answer for the add is the song with the position it got.
    adapter.queue.add((201, {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'}));

    await repository.addSong(1, 8);
    expect(adapter.lastOptions?.method, 'POST');
    expect(adapter.lastOptions?.uri.path, '/api/playlists/1/songs');
    // track_id is a library id: the same number GET /api/music shows.
    expect(adapter.lastOptions?.data, {'track_id': 8});
  });

  // A 204 has no body, so a delete must not try to read one. The stub answers with something
  // that is not an object: a repository that looked at the body would fail on it here.
  test('a 204 delete is not read as an error', () async {
    final adapter = StubAdapter(204, 'the server sends no body for a 204');
    final repository = PlaylistRepository(Dio()..httpClientAdapter = adapter, loggedIn());

    await repository.removeSong(1, 2);
    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/playlists/1/songs/2');

    await repository.delete(1);
    expect(adapter.lastOptions?.uri.path, '/api/playlists/1');
  });

  test('the message of the server is passed on', () async {
    final repository = PlaylistRepository(
      Dio()..httpClientAdapter = StubAdapter(404, {'error': 'playlist is not in your playlists'}),
      SessionStore(),
    );

    expect(
      () => repository.get(1),
      throwsA(isA<PlaylistException>().having((error) => error.message, 'message', 'playlist is not in your playlists')),
    );
  });

  // Without a session the header is not built at all. A "Bearer null" would be answered as
  // an unknown session, and the page would show a message about a token the app never sent.
  test('a call without a session sends no authorization header', () async {
    final adapter = StubAdapter(401, {'error': 'authorization header with a Bearer token is missing'});
    final repository = PlaylistRepository(Dio()..httpClientAdapter = adapter, SessionStore());

    await expectLater(repository.list(), throwsA(isA<PlaylistException>()));
    expect(adapter.lastOptions?.headers['Authorization'], isNull);
  });

  testWidgets('a created playlist shows up in the list', (tester) async {
    // Answers in the order the page calls them: the list (nothing yet), then the create.
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[]), (201, playlistAnswer)]);

    await openPlaylists(tester, playlists: adapter);

    await tester.enterText(find.byType(TextField).first, 'Favoriten');
    await tester.tap(find.widgetWithText(FilledButton, 'Anlegen'));
    await tester.pumpAndSettle();

    // The page says what it did, in the same words as the button.
    expect(find.textContaining('angelegt'), findsOneWidget);
    expect(find.descendant(of: find.byType(ListTile), matching: find.text('Favoriten')), findsOneWidget);
    expect(adapter.lastOptions?.uri.path, '/api/playlists');
  });

  // The client form is not the trust boundary: a name the server refuses is shown as the
  // server said it, not as the client's own guess.
  testWidgets('a name the server refuses is shown as the server said it', (tester) async {
    // Answers in the order the page calls them: the list, then the name.
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[]), (400, {'error': 'the playlist needs a name'})]);

    await openPlaylists(tester, playlists: adapter);

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.widgetWithText(FilledButton, 'Anlegen'));
    await tester.pumpAndSettle();

    expect(find.text('the playlist needs a name'), findsOneWidget);
  });

  // A song is added at the end, and the position the page shows is the one the server
  // answered with. The song is chosen from the library by its title, not by a number.
  testWidgets('adding a song shows the position the server gave it', (tester) async {
    // Answers in the order the page calls them: the list, opening the playlist with no
    // songs yet, then the add.
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([
      (200, <Object>[playlistAnswer]),
      (200, {...playlistAnswer, 'songs': <Object>[]}),
      (201, {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'}),
    ]);

    final library = StubAdapter(200, [
      {'id': 8.0, 'title': 'Technogal.mp3'},
      {'id': 4.0, 'title': 'lied.wav'},
    ]);

    await openPlaylists(tester, playlists: adapter, library: library);
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hinzufügen'));
    await tester.pumpAndSettle();

    expect(find.text('Song an Position 1 eingefügt.'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Technogal.mp3'), findsOneWidget);
  });

  // Removing a middle slot: the server renumbers, so the row that moves up takes the
  // place of the removed one and the numbering stays 1..n with no gap.
  testWidgets('removing a song renumbers the rows that follow', (tester) async {
    // The list, the detail with two songs, then the delete. The page renumbers locally,
    // so nothing else is asked.
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[playlistAnswer]), (200, detailAnswer), (204, {})]);

    await openPlaylists(tester, playlists: adapter);
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Technogal.mp3'),
      matching: find.byType(IconButton),
    ));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/playlists/1/songs/1');

    expect(find.text('Position 1 entfernt.'), findsOneWidget);
    // 'lied.wav' was at position 2; now it is the first row.
    expect(find.text('Technogal.mp3'), findsNothing);
    expect(find.text('lied.wav'), findsOneWidget);
    expect(find.text('2'), findsNothing);
  });

  // The page does not send a value it did not get from the person: without a picked song
  // there is nothing to add, so nothing is sent.
  testWidgets('adding without a picked song sends nothing', (tester) async {
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[playlistAnswer]), (200, detailAnswer)]);

    await openPlaylists(tester, playlists: adapter);
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hinzufügen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Bitte ein Lied aus der Bibliothek'), findsOneWidget);
    // The list and the detail, and nothing else: no request was invented.
    expect(adapter.requests.length, 2);
  });

  // The list on the left shows how many songs a playlist has. Adding or removing one here
  // changes that number, so it has to say the same as the rows the person is looking at.
  testWidgets('the count in the list follows the rows on the page', (tester) async {
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([
      (200, <Object>[playlistAnswer]),
      (200, {...playlistAnswer, 'songs': <Object>[]}),
      (201, {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'}),
      (204, {}),
    ]);
    final library = StubAdapter(200, [
      {'id': 8.0, 'title': 'Technogal.mp3'},
    ]);

    await openPlaylists(tester, playlists: adapter, library: library);
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hinzufügen'));
    await tester.pumpAndSettle();

    // The list said 0 before; the page has one row, so the list says one too.
    expect(find.widgetWithText(ListTile, '1 Songs'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Technogal.mp3'),
      matching: find.byType(IconButton),
    ));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '0 Songs'), findsOneWidget);
    expect(find.text('Position 1 entfernt.'), findsOneWidget);
  });

  // A playlist without songs cannot fill a queue, so the page says that instead of sending a
  // call that would answer an empty list nobody can play.
  testWidgets('starting an empty playlist sends nothing', (tester) async {
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([
      (200, <Object>[playlistAnswer]),
      (200, {...playlistAnswer, 'songs': <Object>[]}),
    ]);
    final queues = StubAdapter(200, <Object>[]);

    await openPlaylists(tester, playlists: adapter, queues: queues);
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Playlist starten'));
    await tester.pumpAndSettle();

    expect(find.text('Diese Playlist hat noch keine Lieder.'), findsOneWidget);
    expect(queues.requests, isEmpty);
  });

  // The page stays in the navigation stack while the first song opens, so a flag left set
  // would keep its buttons disabled after a refused call.
  testWidgets('the page is usable again after a refused call', (tester) async {
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([
      (200, <Object>[playlistAnswer]),
      (200, detailAnswer),
      (201, playlistAnswer),
    ]);

    final queueAdapter = StubAdapter(404, {'error': 'playlist is not in your playlists'});
    await openPlaylists(tester, playlists: adapter, queues: queueAdapter);
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Playlist starten'));
    await tester.pumpAndSettle();

    expect(find.text('playlist is not in your playlists'), findsOneWidget);

    // A second action still sends a request, which it could not if the flag were still set.
    await tester.enterText(find.byType(TextField).first, 'Neu');
    await tester.tap(find.widgetWithText(FilledButton, 'Anlegen'));
    await tester.pumpAndSettle();
    expect(adapter.requests.length, 3);
  });

  // The point of the whole feature: starting a playlist fills the queue and starts its
  // first song. The queue never learned that a playlist filled it, and it now lives in the
  // bar instead of a page of its own.
  testWidgets('starting a playlist fills the shared queue and plays it', (tester) async {
    // The list, then the detail. The queue answers the fill and the read the sheet does
    // when it is opened.
    final playlistAdapter = StubAdapter(200, <Object>[]);
    playlistAdapter.queue.addAll([(200, <Object>[playlistAnswer]), (200, detailAnswer)]);

    final queueAdapter = StubAdapter(200, queueAnswer);
    final wiring = await openPlaylists(tester, playlists: playlistAdapter, queues: queueAdapter);

    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Playlist starten'));
    await tester.pumpAndSettle();

    // The body is what the endpoint documents: source and source_id, nothing else.
    final fill = queueAdapter.requests.first;
    expect(fill.method, 'POST');
    expect(fill.uri.path, '/api/queue');
    expect(fill.data, {'source': 'playlist', 'source_id': 1});

    // The player reads the same list the app shares.
    expect(wiring.queue.length, 2);
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 4]);

    // The bar is where the queue shows up now.
    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(QueueSheet), matching: find.text('Technogal.mp3')), findsWidgets);
    expect(find.descendant(of: find.byType(QueueSheet), matching: find.text('lied.wav')), findsWidgets);
  });

  testWidgets('a rate limit shows the message without signing the user out', (tester) async {
    final wiring = await openPlaylists(
      tester,
      playlists: StubAdapter(429, {'error': 'too many requests from this address, try again later'}),
    );

    expect(find.textContaining('too many requests'), findsOneWidget);
    // A rate limit is not a lost login; only a 401 drops the session.
    expect(wiring.session.isLoggedIn, isTrue);
  });

  testWidgets('a playlist of another user is shown as the server explains it', (tester) async {
    // The page lists what it has, then asks for one playlist; the server answers that it
    // is not the caller's.
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[playlistAnswer]), (404, {'error': 'playlist is not in your playlists'})]);

    await openPlaylists(tester, playlists: adapter);

    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    expect(find.text('playlist is not in your playlists'), findsOneWidget);
  });

  // Local mode has no server, so a playlist is created and filled from the songs on the
  // device. Starting it puts those songs into the local queue, which the queue page then
  // plays.
  testWidgets('local mode creates a playlist, fills it and starts it', (tester) async {
    final local = LocalLibrary()
      ..add(name: 'song.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    final wiring = await openLocalPlaylists(tester, local);

    await tester.enterText(find.byType(TextField).first, 'Favoriten');
    await tester.tap(find.widgetWithText(FilledButton, 'Anlegen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('angelegt'), findsOneWidget);
    expect(local.playlists.single.name, 'Favoriten');

    await tester.tap(find.widgetWithText(ListTile, 'Favoriten'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('song.mp3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Hinzufügen'));
    await tester.pumpAndSettle();

    expect(find.text('Song an Position 1 eingefügt.'), findsOneWidget);
    expect(local.playlists.single.songs.single.title, 'song.mp3');

    await tester.tap(find.widgetWithText(FilledButton, 'Playlist starten'));
    await tester.pumpAndSettle();

    // Starting a playlist fills the stored queue and plays its first song; the queue is
    // looked at through the bar.
    expect(local.queue.single.title, 'song.mp3');
    expect(wiring.player.localTitle, 'song.mp3');

    // A second song on the device can be put into the queue from the sheet.
    local.add(name: 'zwei.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(QueueSheet), matching: find.text('song.mp3')), findsWidgets);

    await tester.tap(find.text('Lieder hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'zwei.mp3'),
      matching: find.byType(IconButton),
    ));
    await tester.pumpAndSettle();

    expect(local.queue.map((track) => track.title), ['song.mp3', 'zwei.mp3']);
  });

  test('a cover is kept under the key it was saved with', () {
    final covers = CoverStore()..save('server:1', Uint8List.fromList([1, 2, 3]));

    expect(covers['server:1'], [1, 2, 3]);
    expect(covers['server:2'], isNull);
  });

  // The picker's image filter is an offer, not a check: a renamed text file must not be
  // stored as a cover.
  testWidgets('a picked file that is no image is refused', (tester) async {
    final covers = CoverStore();

    await openPlaylists(
      tester,
      playlists: StubAdapter(200, <Object>[]),
      covers: covers,
      pickImage: () async => Uint8List.fromList([1, 2, 3, 4, 5, 6]),
    );

    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('kein Bild'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  // An image picked for a playlist that does not exist yet has no id to be stored under;
  // it belongs to the playlist the create then makes.
  testWidgets('a picked image becomes the cover of the created playlist', (tester) async {
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[]), (201, playlistAnswer)]);
    final covers = CoverStore();

    await openPlaylists(tester, playlists: adapter, covers: covers, pickImage: () async => _png);

    await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Favoriten');
    await tester.tap(find.widgetWithText(FilledButton, 'Anlegen'));
    await tester.pumpAndSettle();

    expect(covers['server:http://127.0.0.1:8080:1'], _png);
    // The row in the list and the detail show the image instead of the mark.
    expect(find.byType(Image), findsWidgets);
  });

  // A phone has less width than the two panes need. The page stacks them instead of
  // overflowing, which a Row with a fixed pane would do.
  testWidgets('a narrow window shows the list above the detail', (tester) async {
    final adapter = StubAdapter(200, <Object>[]);
    adapter.queue.addAll([(200, <Object>[playlistAnswer]), (200, detailAnswer)]);

    await openPlaylists(tester, playlists: adapter, size: const Size(420, 900));
    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    expect(find.text('Technogal.mp3'), findsWidgets);
    // An overflow would be reported here instead of only showing stripes in the app.
    expect(tester.takeException(), isNull);
  });

  // The bar is on every page and has to start the queue stored on the device: the player
  // only knows it after it was started, and playCurrent would find no server queue.
  testWidgets('the bar starts the stored local queue', (tester) async {
    final local = LocalLibrary()..add(name: 'song.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    local.setQueue(local.tracks);
    final wiring = await openLocalPlaylists(tester, local);

    await tester.tap(find.byTooltip('Abspielen'));
    await tester.pumpAndSettle();

    expect(wiring.player.localTitle, 'song.mp3');
  });

  // The Playlists page draws the bar every page draws, and the queue is in it.
  testWidgets('the bar opens the queue from here', (tester) async {
    final queues = StubAdapter(200, <Object>[]);
    await openPlaylists(tester, playlists: StubAdapter(200, <Object>[]), queues: queues);

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    expect(find.byType(QueueSheet), findsOneWidget);
  });
}

/// A 1x1 transparent PNG: what the picker answers in the cover test.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
