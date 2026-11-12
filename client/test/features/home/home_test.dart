import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/settings_store.dart';
import 'package:saphire_client/core/utils/pick_audio.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/library/presentation/library_screen.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';
import 'package:saphire_client/shared/widgets/nav_bar.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

const uploadAnswer = {
  'id': 4.0,
  'uploaded_by': 'lukas',
  'title': 'song.mp3',
  'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
  'size': 1500000.0,
  'content_type': 'audio/mpeg',
  'uploaded_at': 1793974311.0,
};

const userAnswer = {'id': 7.0, 'username': 'lukas'};

/// The plugin cannot answer in a test, so the screen is given fixed files.
PickAudio pickedFiles = () async => [(name: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3]))];

/// The library as GET /api/music answers it. The search on this page filters exactly this,
/// because the server has no search endpoint.
const libraryAnswer = [
  {'id': 4.0, 'title': 'lied.wav'},
  {'id': 8.0, 'title': 'Technogal.mp3'},
];

/// A queue answer with two entries, as POST /api/queue answers it. The second one is there
/// so a test can watch the player move to the next song.
const twoSongQueue = [
  {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
  {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
];

/// Opens the start page with a valid session, so the greeting has a name, and hands the
/// wiring back so a test can check what the page does with the session, the adapters and
/// the player it was given. The player is the one the app shares, so a test can say "this
/// song ended" and see what the bar shows.
Future<Wiring> openHome(
  WidgetTester tester, {
  int userStatus = 200,
  Map<String, Object> userBody = userAnswer,
  int uploadStatus = 201,
  Map<String, Object> uploadBody = uploadAnswer,
  PickAudio? pickAudio,
  PickLocalAudio? pickLocal,
  PickLocalAudio? pickFolder,
  SettingsStore? settings,
  LocalLibrary? localLibrary,
  StubAdapter? uploads,
  StubAdapter? library,
  StubAdapter? queues,
  SongPlayer? audio,
}) async {
  // The test font draws every glyph as wide as the font size, so this page needs
  // more room than the default test window.
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final wiring = Wiring(loggedIn(), libraryAdapter: library, queueAdapter: queues, audio: audio);
  addTearDown(wiring.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        repository: AuthRepository(Dio()..httpClientAdapter = StubAdapter(userStatus, userBody), wiring.session),
        uploads:
            UploadRepository(Dio()..httpClientAdapter = uploads ?? StubAdapter(uploadStatus, uploadBody), wiring.session),
        library: wiring.library,
        queues: wiring.queues,
        playlists: wiring.playlists,
        session: wiring.session,
        player: wiring.player,
        pickAudio: pickAudio ?? pickedFiles,
        pickLocal: pickLocal ?? (() async => null),
        pickFolder: pickFolder ?? (() async => null),
        settings: settings,
        localLibrary: localLibrary,
      ),
    ),
  );
  await tester.pumpAndSettle();

  return wiring;
}

Future<void> upload(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Datei auswählen'));
  await tester.pumpAndSettle();
}

void main() {
  test('the greeting follows the time of day', () {
    expect(greetingFor(DateTime(2026, 11, 7, 9)), 'Guten Morgen');
    expect(greetingFor(DateTime(2026, 11, 7, 15)), 'Guten Nachmittag');
    expect(greetingFor(DateTime(2026, 11, 7, 20)), 'Guten Abend');
  });

  testWidgets('the greeting shows the account name from the session check', (tester) async {
    await openHome(tester);

    expect(find.textContaining('Guten'), findsOneWidget);
    expect(find.textContaining('lukas'), findsOneWidget);
  });

  testWidgets('an uploaded song shows up on the page', (tester) async {
    await openHome(tester);

    await upload(tester);

    expect(find.text('song.mp3'), findsOneWidget);
    expect(find.textContaining('lukas · 1.5 MB'), findsOneWidget);
  });

  // The name on the row is the title the server stored (base name only), not the
  // path the picker handed over.
  testWidgets('the row shows the name the server stored', (tester) async {
    await openHome(
      tester,
      uploadBody: {
        'id': 4.0,
        'uploaded_by': 'lukas',
        'title': 'evil.mp3',
        'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
        'size': 1500000.0,
        'content_type': 'audio/mpeg',
        'uploaded_at': 1793974311.0,
      },
      pickAudio: () async => [(name: '../evil.mp3', bytes: Uint8List.fromList([1, 2, 3]))],
    );

    await upload(tester);

    expect(find.text('evil.mp3'), findsOneWidget);
    expect(find.text('../evil.mp3'), findsNothing);
  });

  // The server said this token is gone, so the app must not keep it.
  testWidgets('a session the server rejects is dropped from the store', (tester) async {
    final wiring = await openHome(tester, userStatus: 401, userBody: {'error': 'session is not valid or expired'});

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(wiring.session.isLoggedIn, false);
  });

  // Which format is allowed is the server's decision, so the file is sent and its
  // answer is shown on that file's row.
  testWidgets('a file the server refuses shows its message on the row of that file', (tester) async {
    await openHome(
      tester,
      pickAudio: () async => [(name: 'notes.txt', bytes: Uint8List.fromList([1, 2, 3]))],
      uploadStatus: 400,
      uploadBody: {'error': 'only audio files are accepted'},
    );

    await upload(tester);

    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('only audio files are accepted'), findsOneWidget);
    expect(find.textContaining('lukas · '), findsNothing);
  });

  testWidgets('every picked file gets its own progress and its own result', (tester) async {
    final adapter = StubAdapter(201, uploadAnswer);
    adapter.queue.add((201, uploadAnswer));
    adapter.queue.add((400, {'error': 'only audio files are accepted'}));
    final gate = Completer<void>();
    adapter.wait = gate.future;

    await openHome(
      tester,
      uploads: adapter,
      pickAudio: () async => [
        (name: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3])),
        (name: 'notes.txt', bytes: Uint8List.fromList([4, 5, 6])),
      ],
    );

    await upload(tester);

    // The first file is held by the gate, so its row still shows its own progress.
    expect(find.textContaining('wird hochgeladen ·'), findsOneWidget);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('lukas · 1.5 MB'), findsOneWidget);
    expect(find.text('only audio files are accepted'), findsOneWidget);
    expect(find.textContaining('wird hochgeladen'), findsNothing);
  });

  // The screen can be left while a file is still on its way.
  testWidgets('an answer that arrives after the screen is gone does not rebuild it', (tester) async {
    final adapter = StubAdapter(201, uploadAnswer);
    final gate = Completer<void>();
    adapter.wait = gate.future;

    await openHome(
      tester,
      uploads: adapter,
      pickAudio: () async => [
        (name: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3])),
        (name: 'other.mp3', bytes: Uint8List.fromList([4, 5, 6])),
      ],
    );

    await upload(tester);

    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
  });

  // A second tap while the picker is open must not open a second picker.
  testWidgets('uploads cannot be started twice while the picker is open', (tester) async {
    var opened = 0;
    final picker = Completer<List<PickedAudio>?>();

    await openHome(tester, pickAudio: () {
      opened++;
      return picker.future;
    });

    final pick = find.byTooltip('Datei auswählen');
    await tester.tap(pick);
    await tester.pump();

    // The button is off while the picker is open, so the second tap does nothing.
    await tester.tap(pick);
    await tester.pump();
    expect(opened, 1);

    picker.complete(null);
    await tester.pumpAndSettle();

    // It works again once the picker answered.
    await tester.tap(pick);
    await tester.pump();
    expect(opened, 2);
  });

  // The page shows no invented playlists; the Playlists page is where the user's own are.
  testWidgets('the home page has no static playlist rows', (tester) async {
    await openHome(tester);

    expect(find.text('Zuletzt gehört'), findsNothing);
    expect(find.text('Lieblingssongs'), findsNothing);
    expect(find.text('Workout'), findsNothing);
  });

  // One navigation for every page: Playlists appears once, the section heading is gone, and
  // the two labels without a screen yet are there.
  testWidgets('the navigation lists every page once', (tester) async {
    await openHome(tester);

    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Deine Inhalte'), findsNothing);
    expect(find.text('Alben'), findsOneWidget);
    expect(find.text('Künstler*innen'), findsOneWidget);
  });

  // The search is the one place this page shows real songs: it filters the library the page
  // read once, because the server has no search endpoint.
  testWidgets('the search finds a song in the library', (tester) async {
    await openHome(tester, library: StubAdapter(200, libraryAnswer));

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();

    expect(find.text('Suchergebnisse'), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsOneWidget);
    expect(find.text('lied.wav'), findsNothing);
  });

  // The same field finds a song that is only on this device, so the search works with no server.
  testWidgets('the search finds a local song', (tester) async {
    final local = LocalLibrary();

    await openHome(
      tester,
      settings: SettingsStore()..save(localMode: true),
      localLibrary: local,
      pickLocal: () async => [(name: 'song.mp3', path: null, bytes: Uint8List.fromList([0x49, 0x44, 0x33]))],
    );

    await tester.tap(find.byTooltip('Lokale Songs hinzufügen'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'song');
    await tester.pumpAndSettle();

    expect(find.text('Suchergebnisse'), findsOneWidget);
    expect(find.text('song.mp3'), findsOneWidget);

    // What does not match is not a result, and the sections are not repeated under it.
    await tester.enterText(find.byType(TextField), 'nichts');
    await tester.pumpAndSettle();

    expect(find.text('Suchergebnisse'), findsNothing);
    expect(find.text('song.mp3'), findsNothing);
    expect(find.text('Lokale Songs'), findsNothing);
  });

  // Opening a result does not play by itself. It fills the shared queue with that song,
  // the way the Playlists page starts a playlist, and the player reads that queue.
  testWidgets('opening a search result fills the shared queue with that song', (tester) async {
    final queues = StubAdapter(200, twoSongQueue);
    final wiring = await openHome(tester, library: StubAdapter(200, libraryAnswer), queues: queues);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3'));
    await tester.pumpAndSettle();

    expect(queues.lastOptions?.uri.path, '/api/queue');
    expect(queues.lastOptions?.data, {'source': 'track', 'source_id': 8});
    expect(wiring.queue.current?.title, 'Technogal.mp3');
    expect(find.textContaining('Warteschlange · Slot 1'), findsOneWidget);
  });

  // While nothing is playing the bar is not an empty row; it says what would start something.
  testWidgets('the bar says what to do while nothing is playing', (tester) async {
    await openHome(tester);

    expect(find.text('Nichts wird abgespielt'), findsOneWidget);
    expect(find.textContaining('Suche ein Lied'), findsOneWidget);
  });

  testWidgets('the bar plays and pauses the shared player', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openHome(tester, library: StubAdapter(200, libraryAnswer), queues: StubAdapter(200, twoSongQueue), audio: audio);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3'));
    await tester.pumpAndSettle();

    expect(audio.opened, ['$apiBaseUrl/api/music/8']);

    // Playing is what the last tap did, so the bar offers pause first.
    expect(find.widgetWithIcon(IconButton, Icons.pause), findsOneWidget);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.pause));
    await tester.pumpAndSettle();
    expect(find.widgetWithIcon(IconButton, Icons.play_arrow), findsOneWidget);
  });

  // A song that ends on its own has no tap behind it, so the bar needs the player's
  // listener. A page that only rebuilt on a tap would show the song that just finished.
  testWidgets('when a song ends the bar shows the next one', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openHome(tester, library: StubAdapter(200, libraryAnswer), queues: StubAdapter(200, twoSongQueue), audio: audio);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3'));
    await tester.pumpAndSettle();

    audio.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Warteschlange · Slot 2'), findsOneWidget);
    expect(find.textContaining('lied.wav'), findsOneWidget);
  });

  // A song that cannot be opened is not a JSON answer from the server, so the message here
  // is ours. Before this was only the queue exception caught, and the tap said nothing.
  testWidgets('a song that cannot be opened says why', (tester) async {
    final audio = FakePlayer();
    audio.openError = 'das Audioobjekt ist geschlossen';
    addTearDown(audio.dispose);
    await openHome(tester, library: StubAdapter(200, libraryAnswer), queues: StubAdapter(200, twoSongQueue), audio: audio);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Das Lied konnte nicht gespielt werden'), findsOneWidget);
  });

  // An auto-advance has no tap behind it, so the player reports its failure itself and the
  // bar has to show that. A bar that only showed the slot would move on silently.
  testWidgets('an auto-advance that cannot open the next song says why', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openHome(tester, library: StubAdapter(200, libraryAnswer), queues: StubAdapter(200, twoSongQueue), audio: audio);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technogal.mp3'));
    await tester.pumpAndSettle();

    audio.openError = 'das Audioobjekt ist geschlossen';
    audio.complete();
    await tester.pumpAndSettle();

    expect(find.textContaining('Das Lied konnte nicht gespielt werden'), findsOneWidget);
  });

  // A local song that is not in the stored queue must not be dropped by a tap on play: the
  // bar keeps naming it and the file is not opened again.
  testWidgets('the bar resumes a local song that is not in the stored queue', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = await openHome(
      tester,
      settings: SettingsStore()..save(localMode: true),
      localLibrary: LocalLibrary(),
      audio: audio,
      pickLocal: () async => [(name: 'song.mp3', path: null, bytes: Uint8List.fromList([0x49, 0x44, 0x33]))],
    );

    await tester.tap(find.byTooltip('Lokale Songs hinzufügen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('song.mp3'));
    await tester.pumpAndSettle();
    expect(wiring.player.localTitle, 'song.mp3');

    await tester.tap(find.widgetWithIcon(IconButton, Icons.pause));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(IconButton, Icons.play_arrow));
    await tester.pumpAndSettle();

    expect(wiring.player.localTitle, 'song.mp3');
    expect(audio.opened, hasLength(1));
    expect(audio.played, hasLength(2));
  });

  // A local song can be put into the local queue without a server. It is stored with the
  // library, so the queue page can play it after a restart too.
  testWidgets('a long press puts a local song into the local queue', (tester) async {
    final local = LocalLibrary();

    final wiring = await openHome(
      tester,
      settings: SettingsStore()..save(localMode: true),
      localLibrary: local,
      pickLocal: () async => [(name: 'song.mp3', path: null, bytes: Uint8List.fromList([0x49, 0x44, 0x33]))],
    );

    await tester.tap(find.byTooltip('Lokale Songs hinzufügen'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('song.mp3'));
    await tester.pumpAndSettle();

    expect(local.queue.single.title, 'song.mp3');
    // The shared player has the same order, so a tap on play starts this song.
    expect(wiring.player.localQueue.single.title, 'song.mp3');
    expect(find.textContaining('in die Warteschlange gelegt'), findsOneWidget);
  });

  // A whole folder is added at once, without picking every file.
  testWidgets('a folder is added as its songs', (tester) async {
    final local = LocalLibrary();

    await openHome(
      tester,
      settings: SettingsStore()..save(localMode: true),
      localLibrary: local,
      pickFolder: () async => [
        (name: 'a.mp3', path: 'C:/musik/a.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33])),
        (name: 'b.mp3', path: 'C:/musik/b.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33])),
      ],
    );

    await tester.tap(find.byTooltip('Ordner auswählen'));
    await tester.pumpAndSettle();

    expect(local.tracks.map((track) => track.title), ['a.mp3', 'b.mp3']);
    expect(find.text('a.mp3'), findsOneWidget);
  });

  // A browser has no folders, so the picker can fail. That is not a refused file, so the
  // page says what to do next instead of naming one file.
  testWidgets('a folder that cannot be read says what to do next', (tester) async {
    await openHome(tester, pickFolder: () async => throw UnsupportedError('keine Ordner'));

    await tester.tap(find.byTooltip('Ordner auswählen'));
    await tester.pumpAndSettle();

    // The picker's own reason is kept: "try again" would never work here.
    expect(find.text('keine Ordner'), findsOneWidget);
  });

  testWidgets('a folder without songs says so', (tester) async {
    await openHome(tester, pickFolder: () async => []);

    await tester.tap(find.byTooltip('Ordner auswählen'));
    await tester.pumpAndSettle();

    expect(find.text('In diesem Ordner sind keine MP3-Dateien.'), findsOneWidget);
  });

  // Below AppShell.wideAt the sidebar has no room, so the navigation becomes the row at the bottom
  // of the page — the row a thumb reaches without the other hand. Only the items that lead
  // somewhere are on it, and each is as tall as a touch is aimed at.
  testWidgets('on a phone the navigation row is at the bottom and still navigates', (tester) async {
    tester.view..physicalSize = const Size(420, 900)..devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final wiring = Wiring(
      loggedIn(),
      libraryAdapter: StubAdapter(200, libraryAnswer),
      queueAdapter: StubAdapter(200, <Object>[]),
    );
    addTearDown(wiring.dispose);

    // Home asks who the session belongs to and drops it when the answer is not there, so that call
    // has to answer; without it the guard would leave the test on the login.
    final auth = AuthRepository(Dio()..httpClientAdapter = StubAdapter(200, userAnswer), wiring.session);
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

    // The row is the only navigation in this shape, and it is the last thing on the screen, below
    // the bar.
    final row = find.byType(NavBar);
    expect(row, findsOneWidget);
    expect(tester.getRect(row).bottom, closeTo(900, 1));
    expect(tester.getRect(row).top, greaterThanOrEqualTo(tester.getRect(find.byType(PlayerBar)).bottom));

    // A label with no screen behind it is not on a row a person is trying to reach with one thumb.
    expect(find.text('Suche'), findsNothing);
    expect(find.text('Alben'), findsNothing);
    expect(find.text('Künstler*innen'), findsNothing);

    expect(
      tester.getRect(find.ancestor(of: find.text('Bibliothek'), matching: find.byType(InkWell))).height,
      greaterThanOrEqualTo(48),
    );

    await tester.tap(find.text('Bibliothek'));
    await tester.pumpAndSettle();

    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(find.text('Technogal.mp3'), findsOneWidget);
  });
}

