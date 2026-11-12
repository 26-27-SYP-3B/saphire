import 'dart:ui';

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

// A queue answer as the server sends it: position, track_id, title, and nothing that says what
// filled it or what was played before.
const queueAnswer = [
  {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
  {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
  {'position': 3.0, 'track_id': 7.0, 'title': 'solo.mp3'},
];

// One playlist, so the menu has something it can add a song to.
const playlistAnswer = {'id': 1.0, 'name': 'Favoriten', 'created_at': 1794180269.0, 'song_count': 0.0};

// The same songs as the panel gets them from the server, so a test can say what the app knew
// before the panel opened.
List<QueueEntry> mirror(List<Map<String, Object>> answer) =>
    answer.map((row) => QueueEntry.fromJson(row.cast<String, dynamic>())).toList();

/// Opens the app on the queue panel with a valid session, so the guard lets a test reach it, and
/// hands the wiring back. The player is the one the app shares, so a test can say "this song
/// ended" and see what the panel does with it.
///
/// `prep` runs before the panel opens. What filled the list, which song this device plays and
/// which rows are the person's own are things a queue answer does not carry, so a test that wants
/// the panel to show them has to say them first, the way a page would have.
Future<Wiring> openQueue(
  WidgetTester tester, {
  StubAdapter? queues,
  StubAdapter? playlists,
  SongPlayer? audio,
  SessionStore? session,
  bool phone = false,
  Future<void> Function(Wiring wiring)? prep,
}) async {
  // The panel needs room for the tabs and the rows; the small window is what a phone is.
  tester.view..physicalSize = phone ? const Size(420, 900) : const Size(1200, 900)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = session ?? loggedIn();
  final wiring = Wiring(store, queueAdapter: queues, playlistAdapter: playlists, audio: audio);
  addTearDown(wiring.dispose);

  if (prep != null) await prep(wiring);

  final auth = AuthRepository(Dio(), store);
  final router = buildRouter(
    auth: auth,
    uploads: UploadRepository(Dio(), store),
    library: wiring.library,
    // Nothing here opens the playlists page, but the app is one piece and its pages share the
    // queue, so the test builds the app as main.dart does.
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

/// A row of the panel, by the title it shows.
Finder row(WidgetTester tester, String title) => find.ancestor(of: find.text(title), matching: find.byType(InkWell));

/// Moves the pointer onto a row, which is what replaces its cover with the play symbol.
Future<void> hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}

/// Press and hold a row's handle, move it onto another row and let go.
Future<void> dragFromHandle(WidgetTester tester, Finder handle, Finder target) async {
  final gesture = await tester.startGesture(tester.getCenter(handle));
  await tester.pump(const Duration(milliseconds: 600)); // the hold that starts a long-press drag
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  test('reads a queue answer', () async {
    final repository = QueueRepository(Dio()..httpClientAdapter = StubAdapter(200, queueAnswer), loggedIn());

    final entries = await repository.read();
    expect(entries.map((entry) => entry.position), [1, 2, 3]);
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

    // The whole library needs no id; sending one is refused by the server, so it must not be
    // sent here.
    await repository.fill(QueueSource.library());
    expect(adapter.lastOptions?.data, {'source': 'library'});

    await repository.fill(QueueSource.track(9));
    expect(adapter.lastOptions?.data, {'source': 'track', 'source_id': 9});

    expect(adapter.lastOptions?.uri.path, '/api/queue');
  });

  // Filling is not adding: starting a second playlist must not keep the songs of the first. This
  // is the behaviour a player depends on.
  test('filling replaces the queue', () {
    final queue = PlaybackQueue();

    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
      QueueEntry(position: 2, trackId: 4, title: 'lied.wav'),
    ]);
    expect(queue.length, 2);

    // Filling does not decide what plays. A queue is an order; which song a device plays is that
    // device's state, and the server does not store it either.
    expect(queue.current, isNull);

    queue.fill([QueueEntry(position: 1, trackId: 9, title: 'solo.mp3')]);
    expect(queue.length, 1);
    expect(queue.current, isNull);
  });

  // A queue does not know what filled it, so a plain queue feature later is another source here
  // and not a different queue.
  test('a queue behaves the same whatever filled it', () async {
    final fromPlaylist = PlaybackQueue();
    final fromOneSong = PlaybackQueue();

    fromPlaylist.fill([
      QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
      QueueEntry(position: 2, trackId: 4, title: 'lied.wav'),
    ]);
    fromOneSong.fill([QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3')]);

    // The same steps on both: the first song, then what follows it. Nothing here can report a
    // source, so there is no field a test could check.
    expect(fromPlaylist.advance()?.trackId, 8);
    expect(fromOneSong.advance()?.trackId, 8);

    // Both move on the same way; one has nothing after it.
    expect(fromPlaylist.advance()?.trackId, 4);
    expect(fromOneSong.advance(), isNull);

    expect(fromPlaylist.entries.first.position, 1);
  });

  // "Zuletzt gespielt" lists songs this device started. A row whose file could not be read was
  // never started, so it does not belong there.
  test('a song that was never opened is not recorded as played', () async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = Wiring(loggedIn(), audio: audio);

    wiring.queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);

    audio.openError = 'das Audioobjekt ist geschlossen';
    try {
      await wiring.player.next();
    } catch (_) {
      // The open failed, so the player reports it; nothing was started.
    }
    expect(wiring.queue.history, isEmpty);

    // The same row is skipped when the player moves on from it.
    try {
      await wiring.player.next();
    } catch (_) {
      // Still nothing was started.
    }
    expect(wiring.queue.history, isEmpty);
    expect(wiring.queue.current?.title, 'b');
  });

  // The two sections of the panel are the difference between a song the person put there
  // themselves and a song that is part of the list being played. Only the app knows which, so the
  // mirror has to keep it across a renumbering.
  test('a song added by hand is told apart from a song of a list', () {
    final queue = PlaybackQueue();

    // A playlist names itself, so its rows are the list being played.
    queue.fill([QueueEntry(position: 1, trackId: 8, title: 'a')], fromName: 'Favoriten');
    expect(queue.filledFrom, 'Favoriten');
    expect(queue.entries.first.manual, isFalse);

    // A song added through the plain queue feature has no list behind it.
    queue.append(QueueEntry(position: 2, trackId: 4, title: 'b'));
    expect(queue.entries.map((entry) => entry.manual), [false, true]);

    // The renumbering a removal does must not lose which row was whose.
    queue.removeAt(1);
    expect(queue.entries.map((entry) => entry.manual), [true]);
  });

  // The order a person drags into has to be the order the player goes through, and the song that
  // is audible must stay audible.
  test('moving a row renumbers the slots and leaves the current song alone', () {
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
      QueueEntry(position: 3, trackId: 7, title: 'c'),
    ]);
    queue.advance();

    // Moving a row past the current one: the numbers are the ones the next read would answer
    // with, and the current song is still the current song.
    expect(queue.move(2, 0), isTrue);
    expect(queue.entries.map((entry) => entry.trackId), [7, 8, 4]);
    expect(queue.entries.map((entry) => entry.position), [1, 2, 3]);
    expect(queue.current?.trackId, 8);

    // Moving the row that is current keeps it current.
    expect(queue.move(1, 2), isTrue);
    expect(queue.entries.map((entry) => entry.trackId), [7, 4, 8]);
    expect(queue.current?.trackId, 8);

    // A slot the mirror does not have is not a move.
    expect(queue.move(0, 3), isFalse);
  });

  // "Zuletzt gespielt" is the list of songs this device played, newest first. A row that was
  // never played cannot be in it.
  test('the history keeps the played songs newest first and stays bounded', () {
    final queue = PlaybackQueue();

    queue.recordPlayed(QueueEntry(position: 1, trackId: 8, title: 'a'));
    queue.recordPlayed(QueueEntry(position: 2, trackId: 4, title: 'b'));

    expect(queue.history.map((entry) => entry.title), ['b', 'a']);

    for (var i = 0; i < 60; i++) {
      queue.recordPlayed(QueueEntry(position: 1, trackId: i, title: 'x$i'));
    }

    // A player left open for days must not grow without end.
    expect(queue.history.length, 50);
    expect(queue.history.first.title, 'x59');
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

    // The last row: nothing is left, so the queue is finished rather than pointing at nothing.
    expect(queue.removeAt(1), isTrue);
    expect(queue.isEmpty, isTrue);
    expect(queue.current, isNull);

    // A position this copy does not have is not a removal. The server can hold more songs than
    // the mirror shows, so the page must not report one it did not have.
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

  // Without a session the header is not built at all. A "Bearer null" would be answered as an
  // unknown session, and the page would show a message about a token the app never sent.
  test('a call without a session sends no authorization header', () async {
    final adapter = StubAdapter(401, {'error': 'authorization header with a Bearer token is missing'});
    final repository = QueueRepository(Dio()..httpClientAdapter = adapter, SessionStore());

    await expectLater(repository.read(), throwsA(isA<QueueException>()));
    expect(adapter.lastOptions?.headers['Authorization'], isNull);
  });

  testWidgets('the panel shows the queue as the server has it, with the queue tab open', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    await openQueue(tester, queues: adapter);

    expect(find.text('Zuletzt gespielt'), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsOneWidget);
    expect(find.text('solo.mp3'), findsOneWidget);

    // Nothing is current until the player starts one: the server keeps the order, the device
    // decides what it plays. So there is no "Läuft gerade" section yet.
    expect(find.text('Läuft gerade'), findsNothing);
    expect(find.textContaining('Noch nichts gespielt'), findsNothing);
    expect(adapter.requests.first.uri.path, '/api/queue');
  });

  // The panel is opened from the player, so it must not stop what is playing: it only reads.
  testWidgets('opening the panel does not touch the player', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    expect(audio.opened, isEmpty);
    expect(audio.played, isEmpty);
    expect(audio.stopped, isEmpty);
  });

  testWidgets('clicking a row plays it at once and the queue goes on from there', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(row(tester, 'lied.wav'));
    await tester.pumpAndSettle();

    expect(audio.opened, ['$apiBaseUrl/api/music/4']);
    expect(wiring.queue.current?.trackId, 4);
    expect(find.text('Läuft gerade'), findsOneWidget);

    // Clicking a row does not play one song outside the list: the queue goes on after it.
    audio.complete();
    await tester.pumpAndSettle();

    expect(audio.opened, ['$apiBaseUrl/api/music/4', '$apiBaseUrl/api/music/7']);
    expect(wiring.queue.current?.trackId, 7);
  });

  // A row shows what it is for while the pointer is on it.
  testWidgets('a row shows the play symbol while the pointer is on it', (tester) async {
    await openQueue(tester, queues: StubAdapter(200, queueAnswer));

    expect(find.descendant(of: row(tester, 'lied.wav'), matching: find.byIcon(Icons.play_arrow)), findsNothing);

    await hover(tester, row(tester, 'lied.wav'));
    expect(find.descendant(of: row(tester, 'lied.wav'), matching: find.byIcon(Icons.play_arrow)), findsOneWidget);
  });

  // Songs the person put in the queue themselves and songs of the list being played are shown
  // apart. The server answer cannot say which is which, so the panel shows what it was told.
  testWidgets('songs added by hand are shown apart from the songs of a list', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);

    await openQueue(
      tester,
      queues: adapter,
      prep: (wiring) async {
        // What the Playlists page would have done: fill from a playlist, then add one song of
        // its own.
        wiring.queue.fill(mirror([queueAnswer.first, queueAnswer.last]), fromName: 'Favoriten');
        wiring.queue.append(QueueEntry(position: 3, trackId: 7, title: 'solo.mp3'));
      },
    );

    expect(find.text('Als Nächstes in der Warteschlange'), findsOneWidget);
    expect(find.text('Als Nächstes aus: Favoriten'), findsOneWidget);

    // The read cannot know origins, so it keeps what the panel already knew.
    expect(find.descendant(of: row(tester, 'solo.mp3'), matching: find.text('deine Warteschlange')), findsOneWidget);
    expect(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.text('Favoriten')), findsOneWidget);
  });

  testWidgets('the three-dot menu takes a row out of the queue', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    await openQueue(tester, queues: adapter);

    await tester.tap(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();

    expect(find.text('Aus Warteschlange entfernen'), findsOneWidget);
    expect(find.text('Als Nächstes abspielen'), findsOneWidget);
    expect(find.text('Zur Playlist hinzufügen'), findsOneWidget);

    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue/1');
    expect(find.text('Position 1 entfernt.'), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsNothing);
  });

  // "Als Nächstes abspielen" does not start the song; it puts the row behind the one that is
  // playing.
  testWidgets('the menu puts a row behind the song that is playing', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: row(tester, 'solo.mp3'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Als Nächstes abspielen'));
    await tester.pumpAndSettle();

    // The song that is audible is still audible, and the row now comes right after it.
    expect(wiring.queue.current?.trackId, 8);
    expect(audio.played, ['$apiBaseUrl/api/music/8']);
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 7, 4]);
    expect(find.text('Das Lied wird als nächstes gespielt.'), findsOneWidget);
  });

  testWidgets('the menu adds the song to a playlist', (tester) async {
    // Answers in the order the panel calls them: the queue, the playlists, then the add.
    final queues = StubAdapter(200, queueAnswer);
    final playlists = StubAdapter(200, <Object>[]);
    playlists.queue.addAll([
      (200, <Object>[playlistAnswer]),
      (201, {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'}),
    ]);

    await openQueue(tester, queues: queues, playlists: playlists);

    await tester.tap(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();

    expect(find.text('Keine Playlist'), findsNothing);

    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    expect(playlists.lastOptions?.uri.path, '/api/playlists/1/songs');
    expect(find.text('Song an Position 1 zur Playlist hinzugefügt.'), findsOneWidget);
  });

  // Dragging at the handle is what changes the order, and the song that is playing must not be
  // the one that moves.
  testWidgets('dragging a row by its handle changes the order and the song keeps playing', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    await dragFromHandle(
      tester,
      find.descendant(of: row(tester, 'solo.mp3'), matching: find.byIcon(Icons.drag_handle)),
      row(tester, 'lied.wav'),
    );

    expect(find.text('Das Lied ist jetzt an Position 2.'), findsOneWidget);
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 7, 4]);

    // Nothing was played or stopped: a move is an order, not a new song.
    expect(audio.opened, ['$apiBaseUrl/api/music/8']);
    expect(audio.stopped, isEmpty);
    expect(wiring.queue.current?.trackId, 8);
  });

  // On a phone a row is taken out by swiping it left.
  testWidgets('swiping a row left on a phone takes it out of the queue', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    final wiring = await openQueue(tester, queues: adapter, phone: true);

    await tester.fling(find.byType(Dismissible).first, const Offset(-300, 0), 300);
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue/1');
    expect(wiring.queue.entries.map((entry) => entry.trackId), [4, 7]);
  });

  // Clearing takes out only what the person put there themselves: the song being listened to
  // stays, and the list being played stays.
  testWidgets('clearing takes out only the songs added by hand', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    // Three songs of a playlist and one the person put there themselves. The read must answer
    // with the own song too, because the panel reads the queue when it opens.
    const ownAnswer = [
      ...queueAnswer,
      {'position': 4.0, 'track_id': 9.0, 'title': 'eigenes.mp3'},
    ];
    final adapter = StubAdapter(204, const {})..queue.add((200, ownAnswer));

    final wiring = await openQueue(
      tester,
      queues: adapter,
      audio: audio,
      prep: (wiring) async {
        // What the app knew before the panel opened: the list that filled it, which row is the
        // person's own, and which song this device plays.
        wiring.queue.fill(mirror(ownAnswer), fromName: 'Favoriten');
        wiring.queue.append(QueueEntry(position: 4, trackId: 9, title: 'eigenes.mp3'));
        await wiring.player.playCurrent();
      },
    );

    await tester.tap(find.text('Warteschlange leeren'));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue/4');

    // The row being listened to stays, and the rows that came from the playlist stay.
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 4, 7]);
    expect(wiring.queue.current?.trackId, 8);
    expect(audio.stopped, isEmpty);
    expect(find.text('Eigene Songs entfernt.'), findsOneWidget);
  });

  // A song that ends on its own moves to the next row, and the one that ended is what the second
  // tab shows. Nothing was tapped, so this is the listener.
  testWidgets('when a song ends the previous one appears in the history tab', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    audio.complete();
    await tester.pumpAndSettle();

    expect(wiring.queue.current?.trackId, 4);

    await tester.tap(find.text('Zuletzt gespielt'));
    await tester.pumpAndSettle();

    expect(find.text('Technogal.mp3'), findsOneWidget);
  });

  // A song that is no longer in the list cannot be played from the queue, so it is added back the
  // way the plain queue feature does.
  // A row is the song, not the object the mirror held at the time: a removal renumbers the rows
  // after it, so a history entry that is still in the list is the same row and must not be
  // added a second time.
  testWidgets('a history song that is still in the list is played from that row', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final adapter = StubAdapter(204, const {})..queue.add((200, queueAnswer));

    final wiring = await openQueue(tester, queues: adapter, audio: audio);

    // The last row is played, then ends on its own: it stays in the list and goes to the history.
    await tester.tap(row(tester, 'solo.mp3'));
    await tester.pumpAndSettle();
    audio.complete();
    await tester.pumpAndSettle();

    // A removal in front of it renumbers the row, so the history entry is no longer the same
    // object as the row in the list.
    await tester.tap(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    expect(adapter.requests.length, 2); // the read and the delete, nothing added

    await tester.tap(find.text('Zuletzt gespielt'));
    await tester.pumpAndSettle();
    await tester.tap(row(tester, 'solo.mp3'));
    await tester.pumpAndSettle();

    expect(adapter.requests.length, 2);
    expect(wiring.queue.current?.trackId, 7);
  });

  // Pausing does not lose the row this device is at, so a read keeps it.
  testWidgets('a read keeps the row a paused player is at', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = await openQueue(
      tester,
      queues: StubAdapter(200, queueAnswer),
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(mirror(queueAnswer));
        await wiring.player.playCurrent();
        await wiring.player.pause();
      },
    );

    expect(wiring.queue.current?.trackId, 8);
    expect(find.text('Läuft gerade'), findsOneWidget);
  });

  // The row that is playing cannot be put behind itself, so the menu does not claim a move it
  // did not do.
  testWidgets('the menu does not report a move for the row that is already next', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openQueue(tester, queues: StubAdapter(200, [queueAnswer.first]), audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Als Nächstes abspielen'));
    await tester.pumpAndSettle();

    expect(find.text('Das Lied wird als nächstes gespielt.'), findsNothing);
  });

  testWidgets('a history song that is not in the list is added back before it plays', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final adapter = StubAdapter(200, [queueAnswer.first]);
    adapter.queue.addAll([(200, [queueAnswer.first]), (204, {}), (201, {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'})]);

    final wiring = await openQueue(tester, queues: adapter, audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    // The song ends on its own, which is what puts it in "Zuletzt gespielt".
    audio.complete();
    await tester.pumpAndSettle();

    // Then the row is taken out of the list, so only the history still has this song.
    await tester.tap(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zuletzt gespielt'));
    await tester.pumpAndSettle();
    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'POST');
    expect(adapter.lastOptions?.uri.path, '/api/queue/songs');
    expect(audio.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/8']);
    expect(wiring.queue.current?.trackId, 8);
  });

  // An empty queue is not an empty screen; it says what would fill it.
  testWidgets('an empty queue says what to do next', (tester) async {
    await openQueue(tester, queues: StubAdapter(200, <Object>[]));

    expect(find.text('Füge Songs zur Warteschlange hinzu'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Songs suchen'), findsOneWidget);
  });

  // What a device is playing is its own, the server does not know it. A read may not lose it: the
  // panel keeps pointing at the same song where the server now has it.
  testWidgets('a read keeps pointing at the song this device is playing', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    // Another device put the same song at another slot.
    final adapter = StubAdapter(200, [queueAnswer.last, queueAnswer.first]);

    final wiring = await openQueue(
      tester,
      queues: adapter,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(mirror(queueAnswer));
        await wiring.player.playCurrent();
      },
    );

    // The same song, only at another slot: a read keeps what this device is playing.
    expect(wiring.queue.current?.trackId, 8);
    expect(audio.stopped, isEmpty);
    expect(find.text('Läuft gerade'), findsOneWidget);
  });

  // Only a 401 says the token is gone. A rate limit is not a lost login: the panel shows the
  // message and stays signed in.
  testWidgets('a rate limit shows the message without signing the user out', (tester) async {
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(429, {'error': 'too many requests from this address, try again later'}),
      playlists: StubAdapter(429, {'error': 'too many requests from this address, try again later'}),
      session: loggedIn(),
    );

    expect(find.textContaining('too many requests'), findsOneWidget);
    expect(wiring.session.isLoggedIn, isTrue);
  });

  testWidgets('a session the server rejects is dropped from the store', (tester) async {
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(401, {'error': 'session is not valid or expired'}),
      playlists: StubAdapter(401, {'error': 'session is not valid or expired'}),
      session: loggedIn(),
    );

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(wiring.session.isLoggedIn, isFalse);
  });
}
