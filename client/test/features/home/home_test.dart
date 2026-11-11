import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/utils/pick_audio.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

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
        player: wiring.player,
        pickAudio: pickAudio ?? pickedFiles,
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

  testWidgets('the search field only shows what matches', (tester) async {
    await openHome(tester);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();

    // The rows on the page, not the list in the sidebar.
    expect(find.descendant(of: find.byType(Wrap), matching: find.text('Techno')), findsOneWidget);
    expect(find.descendant(of: find.byType(Wrap), matching: find.text('Workout')), findsNothing);
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
}
