import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/player/data/queue_repository.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

// A queue answer as the server sends it: position, track_id, title, and nothing that says
// what filled it.
const queueAnswer = [
  {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
  {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
];

/// Opens the app on the queue page with a valid session, so the guard lets a test reach
/// it. The player is the one the app shares, so a test can say "this song ended" and see
/// what the page does with it.
Future<Wiring> openQueue(WidgetTester tester, {StubAdapter? queues, SongPlayer? audio, SessionStore? session}) async {
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = session ?? loggedIn();
  final wiring = Wiring(store, queueAdapter: queues, audio: audio);
  addTearDown(wiring.dispose);

  final auth = AuthRepository(Dio(), store);
  final router = buildRouter(
    auth: auth,
    uploads: UploadRepository(Dio(), store),
    // Nothing here opens the playlists page, but the app is one piece and its pages share
    // the queue, so the test builds the app as main.dart does.
    playlists: wiring.playlists,
    queues: wiring.queues,
    queue: wiring.queue,
    player: wiring.player,
    session: store,
  );

  router.go('/queue');
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pumpAndSettle();

  return wiring;
}

void main() {
  test('reads a queue answer', () async {
    final repository = QueueRepository(Dio()..httpClientAdapter = StubAdapter(200, queueAnswer), loggedIn());

    final entries = await repository.read();
    expect(entries.map((entry) => entry.position), [1, 2]);
    expect(entries.first.trackId, 8);
    expect(entries.first.title, 'Technogal.mp3');

    // An empty queue answers [], never null.
    final empty = QueueRepository(Dio()..httpClientAdapter = StubAdapter(200, <Object>[]), loggedIn());
    expect(await empty.read(), isEmpty);
  });

  test('the body only carries source_id where the source needs it', () async {
    final adapter = StubAdapter(200, queueAnswer);
    final repository = QueueRepository(Dio()..httpClientAdapter = adapter, loggedIn());

    await repository.fill(QueueSource.playlist(3));
    expect(adapter.lastOptions?.data, {'source': 'playlist', 'source_id': 3});

    // The whole library needs no id; sending one is refused by the server, so it must not
    // be sent here.
    await repository.fill(QueueSource.library());
    expect(adapter.lastOptions?.data, {'source': 'library'});

    await repository.fill(QueueSource.track(9));
    expect(adapter.lastOptions?.data, {'source': 'track', 'source_id': 9});

    expect(adapter.lastOptions?.uri.path, '/api/queue');
  });

  // Filling is not adding: starting a second playlist must not keep the songs of the
  // first. This is the behaviour a player depends on.
  test('filling replaces the queue', () {
    final queue = PlaybackQueue();

    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
      QueueEntry(position: 2, trackId: 4, title: 'lied.wav'),
    ]);
    expect(queue.length, 2);

    // Filling does not decide what plays. A queue is an order; which song a device plays
    // is that device's state, and the server does not store it either.
    expect(queue.current, isNull);

    queue.fill([QueueEntry(position: 1, trackId: 9, title: 'solo.mp3')]);
    expect(queue.length, 1);
    expect(queue.current, isNull);
  });

  // A queue does not know what filled it, so a plain queue feature later is another
  // source here and not a different queue.
  test('a queue behaves the same whatever filled it', () async {
    final fromPlaylist = PlaybackQueue();
    final fromOneSong = PlaybackQueue();

    fromPlaylist.fill([
      QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
      QueueEntry(position: 2, trackId: 4, title: 'lied.wav'),
    ]);
    fromOneSong.fill([QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3')]);

    // The same steps on both: the first song, then what follows it. Nothing here can
    // report a source, so there is no field a test could check.
    expect(fromPlaylist.advance()?.trackId, 8);
    expect(fromOneSong.advance()?.trackId, 8);

    // Both move on the same way; one has nothing after it.
    expect(fromPlaylist.advance()?.trackId, 4);
    expect(fromOneSong.advance(), isNull);

    expect(fromPlaylist.entries.first.position, 1);
  });

  // The same promise the server makes: positions stay 1..n with no gap.
  test('removing a slot renumbers the rest and follows the current song', () {
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
      QueueEntry(position: 3, trackId: 7, title: 'c'),
    ]);

    // The player is on the first song.
    queue.advance();

    // Removing a row behind the current one: the current song stays, the numbers move up.
    expect(queue.removeAt(3), isTrue);
    expect(queue.entries.map((entry) => entry.position), [1, 2]);
    expect(queue.entries.map((entry) => entry.trackId), [8, 4]);
    expect(queue.current?.trackId, 8);

    // Removing the row that is current moves to the one that takes its place.
    expect(queue.removeAt(1), isTrue);
    expect(queue.current?.trackId, 4);
    expect(queue.entries.map((entry) => entry.position), [1]);

    // The last row: nothing is left, so the queue is finished rather than pointing at
    // nothing.
    expect(queue.removeAt(1), isTrue);
    expect(queue.isEmpty, isTrue);
    expect(queue.current, isNull);

    // A position this copy does not have is not a removal. The server can hold more songs
    // than the mirror shows, so the page must not report one it did not have.
    expect(queue.removeAt(1), isFalse);
  });

  test('advance takes the first song and stops at the end instead of inventing one', () {
    final queue = PlaybackQueue();
    expect(queue.current, isNull);

    queue.fill([QueueEntry(position: 1, trackId: 8, title: 'a')]);
    // Nothing was current, so the first call is the first song; after it there is nothing.
    expect(queue.advance()?.trackId, 8);
    expect(queue.advance(), isNull);

    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);
    expect(queue.advance()?.trackId, 8);
    expect(queue.advance()?.trackId, 4);
    expect(queue.advance(), isNull);
  });

  test('the message of the server is passed on', () async {
    final repository = QueueRepository(
      Dio()..httpClientAdapter = StubAdapter(400, {'error': 'source must be "playlist", "library" or "track"'}),
      SessionStore(),
    );

    expect(
      () => repository.fill(QueueSource.playlist(1)),
      throwsA(isA<QueueException>().having(
        (error) => error.message,
        'message',
        'source must be "playlist", "library" or "track"',
      )),
    );
  });

  // Without a session the header is not built at all. A "Bearer null" would be answered as
  // an unknown session, and the page would show a message about a token the app never sent.
  test('a call without a session sends no authorization header', () async {
    final adapter = StubAdapter(401, {'error': 'authorization header with a Bearer token is missing'});
    final repository = QueueRepository(Dio()..httpClientAdapter = adapter, SessionStore());

    await expectLater(repository.read(), throwsA(isA<QueueException>()));
    expect(adapter.lastOptions?.headers['Authorization'], isNull);
  });

  testWidgets('the page shows the queue as the server has it', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    await openQueue(tester, queues: adapter);

    expect(find.text('Technogal.mp3'), findsOneWidget);
    expect(find.text('lied.wav'), findsOneWidget);
    // Nothing is current until the player starts one: the server keeps the order, the
    // device decides what it plays.
    expect(find.textContaining('Kein Lied wird gespielt'), findsOneWidget);
    expect(adapter.lastOptions?.uri.path, '/api/queue');

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Gerade: Technogal.mp3'), findsOneWidget);
  });

  testWidgets('an empty queue says what to do next', (tester) async {
    await openQueue(tester, queues: StubAdapter(200, <Object>[]));

    expect(find.textContaining('Die Warteschlange ist leer'), findsOneWidget);
    expect(find.textContaining('Kein Lied wird gespielt'), findsOneWidget);
  });

  // Playing a queue entry means asking the streaming endpoint for the song it refers to,
  // with the session token.
  testWidgets('playing opens the song through the streaming endpoint', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    expect(fake.opened, ['$apiBaseUrl/api/music/8']);
    expect(fake.played, ['$apiBaseUrl/api/music/8']);
  });

  // A song that ends on its own moves the page to the next row. Nothing was tapped, so
  // this is the listener: a page that only rebuilt on a tap would still show the song
  // that finished.
  testWidgets('when a song ends the page shows the next one', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    fake.complete();
    await tester.pumpAndSettle();

    expect(wiring.queue.current?.trackId, 4);
    expect(find.textContaining('Gerade: lied.wav'), findsOneWidget);
    expect(fake.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/4']);
  });

  testWidgets('the last song says the queue is finished instead of waiting', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    await openQueue(tester, queues: StubAdapter(200, [queueAnswer.first]), audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Nächstes Lied'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Das war das letzte Lied'), findsOneWidget);
    expect(fake.stopped, ['$apiBaseUrl/api/music/8']);
  });

  // The same promise the playlist endpoint makes: positions stay 1..n with no gap.
  testWidgets('removing a row renumbers the rows after it', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    final wiring = await openQueue(tester, queues: adapter);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Technogal.mp3'),
      matching: find.byType(IconButton),
    ));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue/1');

    expect(find.text('Position 1 entfernt.'), findsOneWidget);
    // 'lied.wav' was at position 2; now it is the first row, and the player is on it.
    expect(find.text('Technogal.mp3'), findsNothing);
    expect(find.textContaining('Gerade: lied.wav'), findsOneWidget);
    expect(wiring.queue.entries.map((entry) => entry.position), [1]);
  });

  // The row being removed can be the one that is playing. The page shows the song that takes
  // its place, so the audio has to move with it; otherwise the removed song is still audible
  // and the one after it is skipped when the current one ends.
  testWidgets('removing the row that is playing moves the audio to the next one', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Technogal.mp3'),
      matching: find.byType(IconButton),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Gerade: lied.wav'), findsOneWidget);
    expect(fake.stopped, ['$apiBaseUrl/api/music/8']);
    expect(fake.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/4']);
  });

  // An error from a song that ends on its own has no tap behind it, so the page would show a
  // new current song without saying that opening it failed.
  testWidgets('an auto-advance that failed is shown as the player reported it', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    fake.openError = 'die Verbindung wurde beendet';
    fake.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Das Lied konnte nicht gespielt werden'), findsOneWidget);
  });

  // A page that keeps its busy flag after an error leaves every button disabled for the rest
  // of its life. After a refused call it has to be usable again.
  testWidgets('the page can act again after a refused call', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    adapter.queue.addAll([(200, queueAnswer), (404, {'error': 'no song at position 1 in this queue'})]);

    await openQueue(tester, queues: adapter);

    await tester.tap(find.descendant(
      of: find.widgetWithText(ListTile, 'Technogal.mp3'),
      matching: find.byType(IconButton),
    ));
    await tester.pumpAndSettle();

    expect(find.text('no song at position 1 in this queue'), findsOneWidget);

    // A second call goes out, which it could not if the flag were still set.
    await tester.tap(find.widgetWithText(TextButton, 'Aktualisieren'));
    await tester.pumpAndSettle();
    expect(adapter.requests.length, 3);
  });

  testWidgets('clearing the queue stops the player and empties the list', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final adapter = StubAdapter(200, queueAnswer);
    final wiring = await openQueue(tester, queues: adapter, audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Leeren'));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue');
    expect(wiring.queue.isEmpty, isTrue);
    expect(find.textContaining('Warteschlange geleert'), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsNothing);
    expect(fake.stopped, ['$apiBaseUrl/api/music/8']);
  });

  // The server said this token is gone, so the app must not keep it: the guard and the
  // page agree on the same session.
  testWidgets('a session the server rejects is dropped from the store', (tester) async {
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(401, {'error': 'session is not valid or expired'}),
      session: loggedIn(),
    );

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(wiring.session.isLoggedIn, isFalse);
  });

  // Only a 401 says the token is gone. A rate limit is not a lost login: the page shows the
  // message and stays signed in.
  testWidgets('a rate limit shows the message without signing the user out', (tester) async {
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(429, {'error': 'too many requests from this address, try again later'}),
      session: loggedIn(),
    );

    expect(find.textContaining('too many requests'), findsOneWidget);
    expect(wiring.session.isLoggedIn, isTrue);
  });

  // What a device is playing is its own, the server does not know it. A refresh may not
  // lose it: the page keeps pointing at the same song where the server now has it.
  testWidgets('a refresh keeps pointing at the song that is playing', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final adapter = StubAdapter(200, queueAnswer);
    adapter.queue.addAll([
      (200, queueAnswer),
      // Another device put the same song at a different slot.
      (200, [queueAnswer.last, queueAnswer.first]),
    ]);

    final wiring = await openQueue(tester, queues: adapter, audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(wiring.queue.current?.trackId, 8);
    expect(find.textContaining('Gerade: Technogal.mp3'), findsOneWidget);
    expect(fake.stopped, isEmpty);
  });

  // A song that is no longer in the list cannot be the current row. Then the audio stops
  // with it, so the page and the audio say the same thing.
  testWidgets('a refresh stops the audio when the playing song is gone from the list', (tester) async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final adapter = StubAdapter(200, queueAnswer);
    adapter.queue.addAll([(200, queueAnswer), (200, [queueAnswer.last])]);

    final wiring = await openQueue(tester, queues: adapter, audio: fake);

    await tester.tap(find.widgetWithText(FilledButton, 'Spielen'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Aktualisieren'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Kein Lied wird gespielt'), findsOneWidget);
    expect(fake.stopped, ['$apiBaseUrl/api/music/8']);
    expect(wiring.queue.current, isNull);
  });
}
