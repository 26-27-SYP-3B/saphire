import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';
import 'package:saphire_client/features/library/presentation/library_screen.dart';
import 'package:saphire_client/features/player/domain/player.dart';

import '../../support/fake_engine.dart';
import '../../support/stub_adapter.dart';

// Numbers as they arrive on the web: as doubles, so the model has to read them
// through num.
const listAnswer = [
  {'id': 4.0, 'title': 'lied.wav'},
  {'id': 8.0, 'title': 'Technogal.mp3'},
];

SessionStore loggedIn() =>
    SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

/// Opens the library with a valid session and hands the player back, because the point of
/// the page is what a tap does to it.
Future<Player> openLibrary(
  WidgetTester tester, {
  int status = 200,
  Object body = listAnswer,
  Map<String, List<String>> headers = const {},
  FakeEngine? engine,
}) async {
  // The test font draws every glyph as wide as the font size, so this page needs
  // more room than the default test window.
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final session = loggedIn();
  final player = Player(engine ?? FakeEngine(), session);
  addTearDown(player.dispose);

  await tester.pumpWidget(
    MaterialApp(
      home: LibraryScreen(
        library: LibraryRepository(Dio()..httpClientAdapter = StubAdapter(status, body, headers: headers), session),
        player: player,
      ),
    ),
  );
  await tester.pumpAndSettle();

  return player;
}

void main() {
  test('reads the list answer as entries', () async {
    final entries = await LibraryRepository(Dio()..httpClientAdapter = StubAdapter(200, listAnswer), loggedIn()).list();

    expect(entries.length, 2);
    expect(entries.first.id, 4);
    expect(entries.first.title, 'lied.wav');
  });

  test('the list call carries the stored token as a Bearer header', () async {
    final adapter = StubAdapter(200, listAnswer);
    await LibraryRepository(Dio()..httpClientAdapter = adapter, loggedIn()).list();

    expect(adapter.lastOptions?.method, 'GET');
    expect(adapter.lastOptions?.uri.path, '/api/music');
    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer ${'a' * 64}');
  });

  // The server answers [] for an empty library, so the page never has to tell an empty
  // library from a missing answer.
  test('an empty library is an empty list', () async {
    final entries = await LibraryRepository(Dio()..httpClientAdapter = StubAdapter(200, []), loggedIn()).list();

    expect(entries, isEmpty);
  });

  test('the message of the server is passed on', () async {
    final repository = LibraryRepository(
      Dio()..httpClientAdapter = StubAdapter(401, {'error': 'session is not valid or expired'}),
      SessionStore(),
    );

    expect(
      () => repository.list(),
      throwsA(isA<LibraryException>().having(
        (error) => error.message,
        'message',
        'session is not valid or expired',
      )),
    );
  });

  testWidgets('the page shows the titles the server listed', (tester) async {
    await openLibrary(tester);

    expect(find.widgetWithText(InkWell, 'lied.wav'), findsOneWidget);
    expect(find.widgetWithText(InkWell, 'Technogal.mp3'), findsOneWidget);
  });

  testWidgets('tapping a song starts the stream for that song', (tester) async {
    final engine = FakeEngine();
    await openLibrary(tester, engine: engine);

    await tester.tap(find.widgetWithText(InkWell, 'Technogal.mp3'));
    // Not pumpAndSettle: while the stream has not reported a length the bar shows an
    // indicator that keeps animating, so the test pumps one frame instead of waiting for
    // an animation that never ends.
    await tester.pump();

    expect(engine.opened, ['http://127.0.0.1:8080/api/music/8']);
  });

  testWidgets('the bar shows the song that was started', (tester) async {
    final engine = FakeEngine();
    await openLibrary(tester, engine: engine);

    await tester.tap(find.widgetWithText(InkWell, 'lied.wav'));
    await tester.pump();

    expect(find.textContaining('lied.wav'), findsWidgets);
    // The bar reflects the engine, so it shows pause once the stream is running.
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  // A length only appears once the stream has read its header; before that there is
  // nothing to seek in, and the bar says so instead of showing a control that cannot be
  // used.
  testWidgets('the bar shows how far the stream is once a length is known', (tester) async {
    final engine = FakeEngine();
    await openLibrary(tester, engine: engine);

    await tester.tap(find.widgetWithText(InkWell, 'lied.wav'));
    engine.report(Duration(seconds: 12), Duration(seconds: 90));
    await tester.pump();

    expect(find.text('00:12 · 01:30'), findsOneWidget);

    await tester.tap(find.byType(Slider));
    await tester.pump();

    expect(engine.calls, contains('seek'));
  });

  testWidgets('an empty library says what to do next', (tester) async {
    await openLibrary(tester, body: []);

    expect(find.text('Noch keine Lieder.'), findsOneWidget);
    expect(find.textContaining('hochladen'), findsOneWidget);
  });

  testWidgets('a library that cannot be read shows the message', (tester) async {
    await openLibrary(
      tester,
      status: 429,
      body: {'error': 'too many requests from this address, try again later'},
      headers: {'retry-after': ['12']},
    );

    expect(
      find.text('too many requests from this address, try again later (Erneut versuchen in 12 s).'),
      findsOneWidget,
    );
    expect(find.widgetWithText(InkWell, 'lied.wav'), findsNothing);
  });
}
