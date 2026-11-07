import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
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

/// The plugin cannot answer in a test, so the screen is given a fixed file.
PickAudio fixedFile = () async => (name: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3]));

/// Opens the start page with a valid session, so the greeting has a name, and
/// hands the session store back so a test can check what the page does with it.
Future<SessionStore> openHome(
  WidgetTester tester, {
  int userStatus = 200,
  Map<String, Object> userBody = userAnswer,
  int uploadStatus = 201,
  Map<String, Object> uploadBody = uploadAnswer,
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
        uploads: UploadRepository(Dio()..httpClientAdapter = StubAdapter(uploadStatus, uploadBody), session),
        pickAudio: fixedFile,
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

  // The server said this token is gone, so the app must not keep it.
  testWidgets('a session the server rejects is dropped from the store', (tester) async {
    final session = await openHome(tester, userStatus: 401, userBody: {'error': 'session is not valid or expired'});

    expect(find.text('session is not valid or expired'), findsOneWidget);
    expect(session.isLoggedIn, false);
  });

  testWidgets('a rejected upload shows what the server said', (tester) async {
    await openHome(tester, uploadStatus: 400, uploadBody: {'error': 'the uploaded file is empty'});

    await upload(tester);

    expect(find.text('the uploaded file is empty'), findsOneWidget);
    expect(find.text('song.mp3'), findsNothing);
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
