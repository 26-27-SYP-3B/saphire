import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/player/data/queue_repository.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';
import 'package:saphire_client/features/player/presentation/queue_panel.dart';
import 'package:saphire_client/shared/widgets/app_shell.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

// A queue answer as the server sends it: position, track_id, title, and nothing that says
// what filled it or what was played before.
const queueAnswer = [
  {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
  {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
  {'position': 3.0, 'track_id': 7.0, 'title': 'solo.mp3'},
];

// One playlist, so the menu has something it can add a song to.
const playlistAnswer = {'id': 1.0, 'name': 'Favoriten', 'created_at': 1794180269.0, 'song_count': 0.0};

/// The same songs as the panel gets them from the server, so a test can say what the app knew
/// before the panel opened.
List<QueueEntry> mirror(List<Map<String, Object>> answer) =>
    answer.map((entry) => QueueEntry.fromJson(entry.cast<String, dynamic>())).toList();

/// Pumps the panel the way AppShell does, with a valid session. The panel is what these tests are
/// about, so it is pumped on its own; the shape is passed in as the parent passes it, and the
/// narrow one is what a phone is. The navigation test in the library test is where the panel is
/// reached through the bar.
///
/// `prep` runs before the panel opens. What filled the list, which song this device plays and
/// which rows are the person's own are things a queue answer does not carry, so a test that wants
/// the panel to show them has to say them first, the way a page would have.
Future<Wiring> openQueue(
  WidgetTester tester, {
  StubAdapter? queues,
  StubAdapter? playlists,
  StubAdapter? library,
  SongPlayer? audio,
  SessionStore? session,
  bool phone = false,
  bool localMode = false,
  LocalLibrary? localLibrary,
  VoidCallback? onClose,
  Future<void> Function(Wiring wiring)? prep,
}) async {
  // The panel needs room for the tabs and the rows; the small window is what a phone is.
  tester.view..physicalSize = phone ? const Size(420, 900) : const Size(1200, 900)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = session ?? loggedIn();
  // A test that does not look at the menu still needs the playlists call to answer something;
  // the default is the empty list, because a real Dio here would be a request to a server that
  // is not there.
  final wiring = Wiring(
    store,
    queueAdapter: queues,
    playlistAdapter: playlists ?? StubAdapter(200, <Object>[]),
    libraryAdapter: library,
    audio: audio,
  );
  addTearDown(wiring.dispose);

  if (prep != null) await prep(wiring);

  await tester.pumpWidget(
    MaterialApp(
      // The rows are ink responses on a sheet, so the panel is pumped inside a frame the way
      // AppShell draws one.
      home: Scaffold(
        body: QueuePanel(
          queues: wiring.queues,
          playlists: wiring.playlists,
          library: wiring.library,
          queue: wiring.queue,
          player: wiring.player,
          session: store,
          localMode: localMode,
          localLibrary: localLibrary,
          phone: phone,
          onClose: onClose,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return wiring;
}

/// A row of the panel, by the title it shows.
Finder row(WidgetTester tester, String title) => find.ancestor(of: find.text(title), matching: find.byType(InkWell));

/// The three-dot menu of a row.
Finder menu(WidgetTester tester, String title) =>
    find.descendant(of: row(tester, title), matching: find.byType(PopupMenuButton<String>));

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

  // The two sections of the panel are the difference between a song the person put there
  // themselves and a song that is part of the list being played. Only the app knows which, so the
  // mirror has to keep it across a renumbering.
  test('a song added by hand is told apart from a song of a list', () {
    final queue = PlaybackQueue();

    // A playlist names itself, so its rows are the list being played.
    queue.fill([QueueEntry(position: 1, trackId: 8, title: 'a')], fromName: 'Favoriten');
    expect(queue.filledFrom, 'Favoriten');
    expect(queue.entries.first.manual, isFalse);

    // A song the person put in the queue themselves is marked as theirs.
    queue.append(QueueEntry(position: 2, trackId: 4, title: 'b', manual: true));
    expect(queue.entries.map((entry) => entry.manual), [false, true]);

    // The renumbering a removal does must not lose which row was whose.
    queue.removeAt(1);
    expect(queue.entries.map((entry) => entry.manual), [true]);
  });

  // The order a person drags into has to be the order the player goes through, and the song that
  // is audible must stay the current one. Positions are 1-based, as the server numbers them.
  test('moving a row renumbers the slots and leaves the current song alone', () {
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
      QueueEntry(position: 3, trackId: 7, title: 'c'),
    ]);
    queue.advance();

    // A row behind the current one moves in front of it: the numbers are the ones the next read
    // would answer with, and the current song is still the current song.
    expect(queue.move(3, 1), isTrue);
    expect(queue.entries.map((entry) => entry.trackId), [7, 8, 4]);
    expect(queue.entries.map((entry) => entry.position), [1, 2, 3]);
    expect(queue.current?.trackId, 8);

    // Moving the row that is current keeps it current.
    expect(queue.move(2, 3), isTrue);
    expect(queue.entries.map((entry) => entry.trackId), [7, 4, 8]);
    expect(queue.current?.trackId, 8);

    // A slot the mirror does not have is not a move, and a row dropped on itself is neither.
    expect(queue.move(0, 3), isFalse);
    expect(queue.move(3, 3), isFalse);
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

  // Only a row the player really opened was played. Pointing at a row is not playing it, so a
  // record is written when the player moves on from a row, not when it becomes current.
  test('a row is recorded only when the player moves on from it', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    // Nothing was played yet, so the second tab has nothing to show.
    expect(queue.history, isEmpty);

    await player.playCurrent();
    // The row the player is on was not played before, so it is not recorded twice.
    expect(queue.history, isEmpty);

    await player.next();
    expect(queue.history.map((entry) => entry.title), ['a']);

    await player.next();
    expect(queue.history.map((entry) => entry.title), ['b', 'a']);

    // The last row: nothing to move on from, so nothing more is recorded.
    expect(await player.next(), isFalse);
    expect(queue.history.length, 2);
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

  testWidgets('the panel shows the queue as the server has it, with the queue tab open', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    await openQueue(tester, queues: adapter);

    // The two tabs are what the panel is: the order and what was played.
    expect(find.byTooltip('Zuletzt gespielt'), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsOneWidget);
    expect(find.text('solo.mp3'), findsOneWidget);

    // Nothing is current until the player starts one: the server keeps the order, the device
    // decides what it plays. So there is no "Läuft gerade" section yet.
    expect(find.text('Läuft gerade'), findsNothing);

    // The panel only reads: opening it is the documented GET /api/queue.
    expect(adapter.requests.first.uri.path, '/api/queue');
  });

  // The panel is opened from the bar, so it must not stop what is playing: it only reads.
  testWidgets('opening the panel does not touch the player', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    expect(audio.opened, isEmpty);
    expect(audio.played, isEmpty);
    expect(audio.stopped, isEmpty);
  });

  // Clicking a row is not hearing one song once: the queue goes on after it, which is what a
  // row in a queue means.
  testWidgets('clicking a row plays it and the queue goes on from there', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(row(tester, 'lied.wav'));
    await tester.pumpAndSettle();

    expect(audio.opened, ['$apiBaseUrl/api/music/4']);
    expect(wiring.queue.current?.trackId, 4);
    expect(find.text('Läuft gerade'), findsOneWidget);

    audio.complete();
    await tester.pumpAndSettle();

    expect(audio.opened, ['$apiBaseUrl/api/music/4', '$apiBaseUrl/api/music/7']);
    expect(wiring.queue.current?.trackId, 7);
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
        wiring.queue.append(QueueEntry(position: 3, trackId: 7, title: 'solo.mp3', manual: true));
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

    await tester.tap(menu(tester, 'Technogal.mp3'));
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

  // "Als Nächstes abspielen" does not start the song; it moves the row. What the panel moves is
  // the row onto the slot the playing row has (queue_panel.dart passes `current + 1`, the playing
  // row's own position), so the order here is what the code produces, not what the label says.
  testWidgets('the menu puts a row behind the song that is playing', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    await tester.tap(menu(tester, 'solo.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Als Nächstes abspielen'));
    await tester.pumpAndSettle();

    // The song that is audible is still audible, and nothing was opened a second time. The row
    // lands in the slot after it, which is what "als nächstes" means.
    expect(wiring.queue.current?.trackId, 8);
    expect(audio.played, ['$apiBaseUrl/api/music/8']);
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 7, 4]);
    expect(find.text('Das Lied wird als nächstes gespielt.'), findsOneWidget);
  });

  // The row that is playing cannot be put behind itself, so the menu does not claim a move it
  // did not do.
  testWidgets('the menu does not report a move for the row that is already next', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openQueue(tester, queues: StubAdapter(200, [queueAnswer.first]), audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    await tester.tap(menu(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Als Nächstes abspielen'));
    await tester.pumpAndSettle();

    expect(find.text('Das Lied wird als nächstes gespielt.'), findsNothing);
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

    await tester.tap(menu(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    // Without one to choose the menu says that, instead of a row nothing can be added to.
    expect(find.text('Keine Playlist'), findsNothing);

    await tester.tap(find.text('Favoriten'));
    await tester.pumpAndSettle();

    expect(playlists.lastOptions?.uri.path, '/api/playlists/1/songs');
    expect(find.text('Song an Position 1 zur Playlist hinzugefügt.'), findsOneWidget);
  });

  // The handle is what changes the order, and the song that is playing must not be the one that
  // moves.
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

  // In the narrow shape a row is taken out by swiping it left; in the wide one it is the menu.
  testWidgets('swiping a row left in the phone shape takes it out of the queue', (tester) async {
    final adapter = StubAdapter(200, queueAnswer);
    final wiring = await openQueue(tester, queues: adapter, phone: true);

    await tester.fling(find.byType(Dismissible).first, const Offset(-300, 0), 300);
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue/1');
    expect(wiring.queue.entries.map((entry) => entry.trackId), [4, 7]);
  });

  // "Warteschlange leeren" takes out only what the person put there themselves: the song being
  // listened to stays, and the list being played stays.
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
        wiring.queue.append(QueueEntry(position: 4, trackId: 9, title: 'eigenes.mp3', manual: true));
        await wiring.player.playCurrent();
      },
    );

    await tester.tap(find.byTooltip('Warteschlange leeren'));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'DELETE');
    expect(adapter.lastOptions?.uri.path, '/api/queue/4');

    // The row being listened to stays, and the rows that came from the playlist stay.
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 4, 7]);
    expect(wiring.queue.current?.trackId, 8);
    expect(audio.stopped, isEmpty);
    expect(find.text('Eigene Songs entfernt.'), findsOneWidget);
  });

  // The same song can be in the queue twice, and the two rows are only different by their number.
  // A menu belongs to the row it was opened on, so the copy that was clicked is the one taken out.
  testWidgets('a menu acts on the row it was opened on, not on the first copy of a song', (tester) async {
    // What the app knew before the panel opened: the same song twice, and this device is at the
    // second copy. The read answers with those four rows, so the row that is playing can only be
    // found by the number it has.
    const twice = [
      ...queueAnswer,
      {'position': 4.0, 'track_id': 4.0, 'title': 'lied.wav'},
    ];
    final adapter = StubAdapter(204, const {})..queue.add((200, twice));

    final wiring = await openQueue(
      tester,
      queues: adapter,
      prep: (wiring) async {
        wiring.queue.fill(mirror(twice));
        wiring.queue.index = 3;
      },
    );

    await tester.tap(find.descendant(of: row(tester, 'Läuft gerade · Position 4'), matching: find.byType(PopupMenuButton<String>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    // The second copy, not the first one with the same title.
    expect(adapter.lastOptions?.uri.path, '/api/queue/4');
    expect(find.text('Position 4 entfernt.'), findsOneWidget);
    expect(wiring.queue.entries.map((entry) => entry.trackId), [8, 4, 7]);
  });

  // A queue without rows is not an empty screen; it says what would fill it. The add tab the
  // sheet had is gone: songs are put in the queue from the library page.
  testWidgets('an empty queue says what to do next', (tester) async {
    await openQueue(tester, queues: StubAdapter(200, <Object>[]));

    expect(find.text('Füge Songs zur Warteschlange hinzu'), findsOneWidget);
    expect(find.textContaining('Such oben nach einem Lied'), findsOneWidget);
  });

  // "Zuletzt gespielt" is what this device played, newest first. Nothing was played before the
  // first row was opened, so a row only appears there once the player moved on from it.
  testWidgets('the history tab shows the row the player moved on from', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = await openQueue(tester, queues: StubAdapter(200, queueAnswer), audio: audio);

    await tester.tap(find.byTooltip('Zuletzt gespielt'));
    await tester.pumpAndSettle();
    // The field narrows the songs of the queue, and the history is not that list.
    expect(find.byType(TextField), findsNothing);
    expect(find.textContaining('Noch nichts gespielt'), findsOneWidget);

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();
    // The row this device is at was not played before, so it is not in the history yet.
    expect(wiring.queue.history, isEmpty);

    audio.complete();
    await tester.pumpAndSettle();
    expect(wiring.queue.current?.trackId, 4);

    await tester.tap(find.byTooltip('Zuletzt gespielt'));
    await tester.pumpAndSettle();
    expect(find.text('Technogal.mp3'), findsOneWidget);
  });

  // A song from this device can be in the history while the queue the page shows is the server's,
  // because the bar plays the device list when nothing on the server is open. Replaying it must not
  // ask the server for a song id, because a file on this device does not have one.
  testWidgets('a device song in the history is played from the device, not from the server', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final local = LocalLibrary()..add(name: 'a.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    final adapter = StubAdapter(200, <Object>[]);

    final wiring = await openQueue(tester, queues: adapter, audio: audio, localLibrary: local);

    await wiring.player.playLocal(local.tracks.first);
    audio.complete();
    await tester.pumpAndSettle();

    expect(wiring.queue.history.map((entry) => entry.title), ['a.mp3']);

    await tester.tap(find.byTooltip('Zuletzt gespielt'));
    await tester.pumpAndSettle();
    await tester.tap(row(tester, 'a.mp3'));
    await tester.pumpAndSettle();

    // The bytes on this device again. The only request is the read the panel does when it opens;
    // there is no POST with a -1 as the song id.
    expect(audio.opened.last, startsWith('data:audio/mpeg'));
    expect(adapter.requests.length, 1);
    expect(adapter.lastOptions?.uri.path, '/api/queue');
  });

  // A row that is only in the history has no slot, so it has no handle and the row says what it
  // is; the row that is still in the list keeps both.

  // A row is the song, not the object the mirror held at the time: a removal renumbers the rows
  // after it, so a history entry that is still in the list is the same row and must not be
  // added a second time.
  testWidgets('a history row that is still in the list is played from that row', (tester) async {
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
    await tester.tap(menu(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    expect(adapter.requests.length, 2); // the read and the delete, nothing added

    await tester.tap(find.byTooltip('Zuletzt gespielt'));
    await tester.pumpAndSettle();
    await tester.tap(row(tester, 'solo.mp3'));
    await tester.pumpAndSettle();

    expect(adapter.requests.length, 2);
    expect(wiring.queue.current?.trackId, 7);
    expect(audio.opened, ['$apiBaseUrl/api/music/7', '$apiBaseUrl/api/music/7']);
  });

  // A song that is no longer in the list cannot be played from the queue, so it is added back the
  // way the plain queue feature does.
  testWidgets('a history row that is not in the list is added back before it plays', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final adapter = StubAdapter(200, [queueAnswer.first]);
    adapter.queue.addAll([
      (200, [queueAnswer.first]),
      (204, {}),
      (201, {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'}),
    ]);

    final wiring = await openQueue(tester, queues: adapter, audio: audio);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    // The song ends on its own, which is what puts it in "Zuletzt gespielt".
    audio.complete();
    await tester.pumpAndSettle();

    // Then the row is taken out of the list, so only the history still has this song.
    await tester.tap(menu(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Zuletzt gespielt'));
    await tester.pumpAndSettle();

    // A row that is only in the history has no slot, so it has no handle, and the row says what
    // it is.
    expect(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.byIcon(Icons.drag_handle)), findsNothing);
    expect(find.descendant(of: row(tester, 'Technogal.mp3'), matching: find.text('Zuletzt gespielt')), findsOneWidget);

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();

    expect(adapter.lastOptions?.method, 'POST');
    expect(adapter.lastOptions?.uri.path, '/api/queue/songs');
    expect(audio.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/8']);
    expect(wiring.queue.current?.trackId, 8);
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

  // What a device is playing is its own, the server does not know it. A read may not lose it: the
  // panel keeps pointing at the same song where the server now has it.
  testWidgets('a read keeps pointing at the song this device is playing', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    // Another device put the same songs at other slots.
    final adapter = StubAdapter(200, [queueAnswer.last, queueAnswer.first, queueAnswer[1]]);

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

  // A song that is no longer in the list cannot be the current row. Then the audio stops with it,
  // so the panel and the audio say the same thing.
  testWidgets('a read stops the audio when the playing song is gone from the list', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final adapter = StubAdapter(200, [queueAnswer.last]);

    final wiring = await openQueue(
      tester,
      queues: adapter,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(mirror(queueAnswer));
        await wiring.player.playCurrent();
      },
    );

    expect(wiring.queue.current, isNull);
    expect(audio.stopped, ['$apiBaseUrl/api/music/8']);
  });

  // A panel that keeps its busy flag after an error leaves every button disabled for the rest of
  // its life. After a refused call it has to be usable again.
  testWidgets('the panel can act again after a refused call', (tester) async {
    // Answers in the order the panel calls them: the read, then the first removal, then the second.
    final adapter = StubAdapter(204, {});
    adapter.queue.addAll([
      (200, queueAnswer),
      (404, {'error': 'no song at position 1 in this queue'}),
    ]);

    await openQueue(tester, queues: adapter);

    await tester.tap(menu(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    expect(find.text('no song at position 1 in this queue'), findsOneWidget);

    // A second call goes out, which it could not if the flag were still set.
    await tester.tap(menu(tester, 'lied.wav'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Aus Warteschlange entfernen'));
    await tester.pumpAndSettle();

    expect(adapter.requests.length, 3);

    // The mirror takes the row out before anything is written, so after the refused call the panel
    // is one row ahead of the server and this removal addresses the new slot. That is what the
    // note says, and only the note: the panel does not claim the write worked.
    expect(adapter.lastOptions?.uri.path, '/api/queue/1');
    expect(find.text('Position 1 entfernt.'), findsOneWidget);
  });

  // Closing takes the panel out of the frame it was drawn in; the audio runs on, because opening
  // the queue never touched it.
  testWidgets('closing the panel gives the frame back and the song keeps playing', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    var closed = false;
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(200, queueAnswer),
      audio: audio,
      onClose: () => closed = true,
    );

    await tester.tap(row(tester, 'Technogal.mp3'));
    await tester.pumpAndSettle();
    expect(audio.played, ['$apiBaseUrl/api/music/8']);

    await tester.tap(find.byTooltip('Warteschlange schließen'));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(audio.stopped, isEmpty);
    expect(wiring.queue.current?.trackId, 8);
  });

  // Without a server the rows are the songs on this device, and the order that is changed is the
  // order stored here. Nothing goes to the network.
  testWidgets('local mode shows the device queue and moves a row in the stored order', (tester) async {
    final local = LocalLibrary();
    local.add(name: 'a.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    local.add(name: 'b.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    local.add(name: 'c.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    // A fill comes from one list, so nothing in it was put there by hand; the third song is.
    local.setQueue(local.tracks.sublist(0, 2), fromName: 'Favoriten');
    local.addToQueue(local.tracks.last);

    final queueAdapter = StubAdapter(200, <Object>[]);
    final wiring = await openQueue(tester, queues: queueAdapter, localMode: true, localLibrary: local);

    // There is nothing to fetch for a device queue: the rows are built from what is stored here.
    expect(queueAdapter.requests, isEmpty);
    expect(find.text('Als Nächstes in der Warteschlange'), findsOneWidget);
    expect(find.text('Als Nächstes aus: Favoriten'), findsOneWidget);

    await dragFromHandle(
      tester,
      find.descendant(of: row(tester, 'c.mp3'), matching: find.byIcon(Icons.drag_handle)),
      row(tester, 'b.mp3'),
    );

    // The stored order is what changes, so it stays after a restart.
    expect(local.queue.map((track) => track.title), ['a.mp3', 'c.mp3', 'b.mp3']);
    expect(wiring.queue.entries.map((entry) => entry.title), ['a.mp3', 'c.mp3', 'b.mp3']);
    expect(find.text('Das Lied ist jetzt an Position 2.'), findsOneWidget);
  });

  // Clearing on a device writes only the store, so the rows must be built from it again; otherwise
  // the page keeps showing songs the store no longer has.
  testWidgets('clearing on a device shows what is left, not the rows it removed', (tester) async {
    final local = LocalLibrary();
    local.add(name: 'a.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    local.add(name: 'b.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    local.add(name: 'c.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    // Two songs from a playlist, which stay, and one the person put there themselves, which goes.
    local.setQueue(local.tracks.sublist(0, 2), fromName: 'Favoriten');
    local.addToQueue(local.tracks.last);

    final wiring = await openQueue(tester, localMode: true, localLibrary: local);

    await tester.tap(find.byTooltip('Warteschlange leeren'));
    await tester.pumpAndSettle();

    expect(row(tester, 'c.mp3'), findsNothing);
    expect(row(tester, 'a.mp3'), findsOneWidget);
    expect(local.queue.map((track) => track.title), ['a.mp3', 'b.mp3']);
    expect(wiring.queue.entries.map((entry) => entry.title), ['a.mp3', 'b.mp3']);
    expect(find.text('Eigene Songs entfernt.'), findsOneWidget);
  });

  // The same rows in both modes: a row on the device opens the file, not the streaming endpoint.
  testWidgets('a local row plays the file on this device', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final local = LocalLibrary()..add(name: 'a.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));
    local.setQueue(local.tracks);

    final wiring = await openQueue(tester, audio: audio, localMode: true, localLibrary: local);

    await tester.tap(row(tester, 'a.mp3'));
    await tester.pumpAndSettle();

    // No server and no token: the song is opened from the bytes the pick gave.
    expect(audio.opened.single, startsWith('data:audio/mpeg'));
    expect(wiring.player.localTitle, 'a.mp3');
    expect(wiring.queue.current?.title, 'a.mp3');
  });

  // Only a 401 says the token is gone; a rate limit is not a lost login.
  testWidgets('a session the server rejects is dropped from the store', (tester) async {
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(401, {'error': 'session is not valid or expired'}),
      session: loggedIn(),
    );

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(wiring.session.isLoggedIn, isFalse);
  });

  testWidgets('a rate limit shows the message without signing the user out', (tester) async {
    final wiring = await openQueue(
      tester,
      queues: StubAdapter(429, {'error': 'too many requests from this address, try again later'}),
      session: loggedIn(),
    );

    expect(find.textContaining('too many requests'), findsOneWidget);
    expect(wiring.session.isLoggedIn, isTrue);
  });

  // The field at the top offers what can be played without leaving the page, and a tap does what a
  // tap on a row does: the song goes into the queue and starts.
  testWidgets('the search offers library songs and plays one', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final queues = StubAdapter(204, const {});
    queues.queue.addAll([
      (200, queueAnswer),
      (201, {'position': 4.0, 'track_id': 13.0, 'title': 'alt.mp3'}),
    ]);

    final wiring = await openQueue(
      tester,
      queues: queues,
      audio: audio,
      library: StubAdapter(200, const [
        {'id': 13.0, 'title': 'alt.mp3'},
        {'id': 12.0, 'title': 'neu.mp3'},
      ]),
    );

    expect(find.text('Vorschläge'), findsOneWidget);
    expect(find.text('alt.mp3'), findsOneWidget);
    expect(find.text('neu.mp3'), findsOneWidget);

    await tester.tap(find.text('alt.mp3'));
    await tester.pumpAndSettle();

    expect(queues.lastOptions?.method, 'POST');
    expect(queues.lastOptions?.uri.path, '/api/queue/songs');
    expect(audio.opened, ['$apiBaseUrl/api/music/13']);
    expect(wiring.queue.current?.trackId, 13);
    // A song the person searched for is their own: "Warteschlange leeren" takes it out again.
    expect(wiring.queue.current?.manual, isTrue);
  });

  // What is typed narrows the same list, which is the point of the field in a drop-up.
  testWidgets('typing narrows the songs the panel offers', (tester) async {
    await openQueue(
      tester,
      queues: StubAdapter(200, queueAnswer),
      library: StubAdapter(200, const [
        {'id': 13.0, 'title': 'alt.mp3'},
        {'id': 12.0, 'title': 'neu.mp3'},
      ]),
    );

    await tester.enterText(find.byType(TextField), 'alt');
    await tester.pumpAndSettle();

    expect(find.text('Suchergebnisse'), findsOneWidget);
    expect(find.text('alt.mp3'), findsOneWidget);
    expect(find.text('neu.mp3'), findsNothing);
  });

  // The list that is playing is what a suggestion should come from, so the field does not offer
  // songs of another playlist or of the whole library while one is playing.
  testWidgets('a playing playlist is what the field suggests from', (tester) async {
    final playlists = StubAdapter(204, const {});
    playlists.queue.addAll([
      (200, <Object>[playlistAnswer]),
      (
        200,
        {
          'id': 1.0,
          'name': 'Favoriten',
          'created_at': 1794180269.0,
          'song_count': 1.0,
          'songs': [
            {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
          ],
        },
      ),
    ]);

    await openQueue(
      tester,
      queues: StubAdapter(200, queueAnswer),
      playlists: playlists,
      library: StubAdapter(200, const [
        {'id': 99.0, 'title': 'nicht.wav'},
      ]),
      prep: (wiring) async => wiring.queue.fill(mirror(queueAnswer), fromName: 'Favoriten'),
    );

    // The song of the playlist is offered and is also a row of the queue.
    expect(find.text('Technogal.mp3'), findsNWidgets(2));
    expect(playlists.lastOptions?.uri.path, '/api/playlists/1');
    expect(find.text('nicht.wav'), findsNothing);
  });

  // On a phone the queue is a drop-up over the page, not the page: the bar stays reachable below
  // it, with the controls of the song that is playing, and the button that opened it closes it.
  testWidgets('a phone shows the queue as a drop-up above the bar', (tester) async {
    tester.view..physicalSize = const Size(420, 900)..devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final wiring = Wiring(
      loggedIn(),
      queueAdapter: StubAdapter(200, queueAnswer),
      playlistAdapter: StubAdapter(200, <Object>[]),
    );
    addTearDown(wiring.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          selected: '/home',
          player: wiring.player,
          queues: wiring.queues,
          playlists: wiring.playlists,
          library: wiring.library,
          session: wiring.session,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = find.descendant(of: find.byType(PlayerBar), matching: find.byTooltip('Warteschlange'));
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsOneWidget);

    final panel = tester.getRect(find.byType(QueuePanel));
    final bar = tester.getRect(find.byType(PlayerBar));
    expect(panel.bottom, closeTo(bar.top, 1));
    expect(panel.height, lessThanOrEqualTo(900 * 0.62));
    expect(tester.takeException(), isNull);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(QueuePanel), findsNothing);
  });
}
