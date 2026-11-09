import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/utils/pick_audio.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/player/data/player.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

import '../../support/stub_adapter.dart';

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

/// Opens the start page with a valid session, so the greeting has a name, and hands
/// the session store and the upload adapter back so a test can check what the page
/// does with them.
Future<SessionStore> openHome(
  WidgetTester tester, {
  int userStatus = 200,
  Map<String, Object> userBody = userAnswer,
  int uploadStatus = 201,
  Map<String, Object> uploadBody = uploadAnswer,
  PickAudio? pickAudio,
  StubAdapter? uploads,
}) async {
  // The test font draws every glyph as wide as the font size, so this page needs
  // more room than the default test window.
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final session =
      SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        repository: AuthRepository(Dio()..httpClientAdapter = StubAdapter(userStatus, userBody), session),
        uploads: UploadRepository(Dio()..httpClientAdapter = uploads ?? StubAdapter(uploadStatus, uploadBody), session),
        // Nothing really plays in a test, so the player only records what it was given.
        player: Player(session, (url, headers) async {}),
        pickAudio: pickAudio ?? pickedFiles,
      ),
    ),
  );
  await tester.pumpAndSettle();

  return session;
}

Future<void> upload(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Eigene Dateien hochladen'));
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
    final session = await openHome(tester, userStatus: 401, userBody: {'error': 'session is not valid or expired'});

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(session.isLoggedIn, false);
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

    await tester.tap(find.widgetWithText(FilledButton, 'Eigene Dateien hochladen'));
    await tester.pumpAndSettle();

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

    await tester.tap(find.widgetWithText(FilledButton, 'Eigene Dateien hochladen'));
    await tester.pumpAndSettle();

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

    await tester.tap(find.widgetWithText(FilledButton, 'Eigene Dateien hochladen'));
    await tester.pump();

    // The chip is a plain label while the picker is open, so there is nothing to tap.
    expect(find.widgetWithText(FilledButton, 'Eigene Dateien hochladen'), findsNothing);
    expect(opened, 1);

    picker.complete(null);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Eigene Dateien hochladen'), findsOneWidget);
    expect(opened, 1);
  });

  testWidgets('the search field only shows what matches', (tester) async {
    await openHome(tester);

    await tester.enterText(find.byType(TextField), 'techno');
    await tester.pumpAndSettle();

    // The rows on the page, not the list in the sidebar.
    expect(find.descendant(of: find.byType(Wrap), matching: find.text('Techno')), findsOneWidget);
    expect(find.descendant(of: find.byType(Wrap), matching: find.text('Workout')), findsNothing);
  });
}
