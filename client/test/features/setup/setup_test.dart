import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/app.dart';
import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/storage/settings_store.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/auth/presentation/auth_screen.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/setup/data/server_check.dart';
import 'package:saphire_client/features/setup/presentation/setup_screen.dart';
import 'package:saphire_client/features/setup/presentation/settings_screen.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

/// The answer that only a Saphire server gives: a session check without a token.
StubAdapter saphireServer() =>
    StubAdapter(401, {'error': 'authorization header with a Bearer token is missing'});

/// An adapter that never answers, which is what a failing transport is.
class NoAnswerAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(requestOptions: options);
  }

  @override
  void close({bool force = false}) {}
}

typedef App = ({SettingsStore settings, SessionStore session, StubAdapter adapter});

/// The launch default, before any test stored a server in the global.
final launchBase = apiBaseUrl;

/// Opens the app the way main.dart does, so the guard decides where a test lands.
Future<App> openApp(
  WidgetTester tester, {
  SettingsStore? settings,
  SessionStore? session,
  StubAdapter? adapter,
}) async {
  // The home screen is part of this flow, so it needs the room its own test uses.
  tester.view..physicalSize = const Size(1600, 1200)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = settings ?? SettingsStore();
  final current = session ?? SessionStore();
  final stub = adapter ?? saphireServer();
  final dio = Dio()..httpClientAdapter = stub;

  // main.dart does this too, and each test starts from the launch default rather
  // than from whatever the previous test saved.
  apiBaseUrl = store.serverBase ?? launchBase;

  final wiring = Wiring(current);
  addTearDown(wiring.dispose);

  await tester.pumpWidget(
    SaphireApp(
      repository: AuthRepository(dio, current),
      uploads: UploadRepository(dio, current),
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: current,
      settings: store,
      dio: dio,
    ),
  );
  await tester.pumpAndSettle();

  return (settings: store, session: current, adapter: stub);
}

Future<void> connect(WidgetTester tester, String url, [String button = 'Verbinden']) async {
  await tester.enterText(find.byType(TextFormField), url);
  await tester.tap(find.widgetWithText(FilledButton, button));
  await tester.pumpAndSettle();
}

void main() {
  test('every trailing slash goes, so the paths stay single', () {
    expect(normalizeBase('https://musik.meinserver.at/'), 'https://musik.meinserver.at');
    expect(normalizeBase('https://musik.meinserver.at///'), 'https://musik.meinserver.at');
  });

  test('only the documented 401 confirms a server', () async {
    expect(
      await checkServer(
        Dio()..httpClientAdapter = saphireServer(),
        'https://musik.meinserver.at',
      ),
      isNull,
    );
    // A 404 page or a 429 from the rate limiter is not a Saphire answer.
    expect(
      await checkServer(
        Dio()..httpClientAdapter = StubAdapter(429, {'error': 'too many requests'}),
        'https://musik.meinserver.at',
      ),
      busyMessage,
    );
    expect(
      await checkServer(
        Dio()..httpClientAdapter = StubAdapter(401, '<html>nope</html>'),
        'https://musik.meinserver.at',
      ),
      'Die Adresse antwortet nicht wie ein Saphire-Server.',
    );
  });

  test('an address that never answers is named as unreachable', () async {
    expect(
      await checkServer(Dio()..httpClientAdapter = NoAnswerAdapter(), 'https://musik.meinserver.at'),
      'Der Server ist nicht erreichbar.',
    );
  });

  testWidgets('the first start opens the setup with the welcome screen', (tester) async {
    await openApp(tester);

    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.text('Willkommen bei Saphire'), findsOneWidget);
    expect(find.text('Gib die Adresse deines Saphire-Servers ein.'), findsOneWidget);
  });

  test('without a stored server even /login leads to the setup', () async {
    final settings = SettingsStore();
    final session = SessionStore();
    final dio = Dio()..httpClientAdapter = saphireServer();
    final wiring = Wiring(session);
    addTearDown(wiring.dispose);

    final router = buildRouter(
      auth: AuthRepository(dio, session),
      uploads: UploadRepository(dio, session),
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: session,
      settings: settings,
      dio: dio,
    );
    addTearDown(router.dispose);

    router.go('/login');

    expect(router.routerDelegate.currentConfiguration.uri.path, '/setup');
  });

  testWidgets('a reachable address is confirmed and the check really goes to the server', (tester) async {
    final app = await openApp(tester);

    await connect(tester, 'https://musik.meinserver.at/');

    expect(find.text('Server bestätigt.'), findsOneWidget);
    // The check goes to the typed host, not to the launch default.
    expect(app.adapter.lastOptions?.uri.host, 'musik.meinserver.at');
    expect(app.adapter.lastOptions?.uri.path, '/api/session');

    // Nothing is stored yet, the address is only saved when the setup is finished.
    expect(app.settings.serverBase, isNull);
    expect(find.widgetWithText(TextButton, 'Weiter'), findsOneWidget);
  });

  testWidgets('an empty field is stopped before any request', (tester) async {
    final app = await openApp(tester);

    await connect(tester, '');

    expect(find.text('Server-Adresse: eine Adresse angeben.'), findsOneWidget);
    expect(app.adapter.requests, isEmpty);
    expect(find.byType(SetupScreen), findsOneWidget);
  });

  // The field keeps its value, so correcting it is one more tap, not a new start.
  testWidgets('a bad address is answered with its message and can be corrected', (tester) async {
    final app = await openApp(tester);

    await connect(tester, 'musik.meinserver.at');

    expect(find.text('Server-Adresse: http:// oder https:// mit Host'), findsOneWidget);
    expect(app.adapter.requests, isEmpty);

    await connect(tester, 'https://musik.meinserver.at');

    expect(find.text('Server bestätigt.'), findsOneWidget);
    expect(find.byType(SetupScreen), findsOneWidget);
  });

  testWidgets('an address with a path is refused before any request', (tester) async {
    final app = await openApp(tester);

    await connect(tester, 'https://musik.meinserver.at/api');

    expect(find.text('Server-Adresse: http:// oder https:// mit Host'), findsOneWidget);
    expect(app.adapter.requests, isEmpty);
  });

  testWidgets('an address edited after the check is not saved unchecked', (tester) async {
    final app = await openApp(tester);

    await connect(tester, 'https://musik.meinserver.at/');
    expect(find.widgetWithText(TextButton, 'Weiter'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField), 'https://musik.anders.at');
    await tester.pumpAndSettle();

    // The confirmation belonged to the old address, so the way on is gone again.
    expect(find.widgetWithText(TextButton, 'Weiter'), findsNothing);
    expect(find.text('Server bestätigt.'), findsNothing);
    expect(app.settings.serverBase, isNull);
  });

  testWidgets('the finished setup saves the server, the login follows, the home screen ends it', (tester) async {
    // The check, then the login, then the home screen's session check: the queue is
    // answered in order, and the fixed answer stands for the last one.
    final app = await openApp(
      tester,
      adapter: (StubAdapter(200, {'id': 7.0, 'username': 'lukas'})
        ..queue.addAll([
          (401, {'error': 'authorization header with a Bearer token is missing'}),
          (200, {'token': 'f' * 64, 'expires_at': 2000000000}),
        ])),
    );

    await connect(tester, 'https://musik.meinserver.at/');
    await tester.tap(find.widgetWithText(TextButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first, 'lukas');
    await tester.enterText(find.byType(TextFormField).last, 'geheim123');
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(app.settings.serverBase, 'https://musik.meinserver.at');
    expect(app.session.isLoggedIn, true);
    // The login and the session check after it went to the new server.
    expect(app.adapter.requests.last.uri.host, 'musik.meinserver.at');
  });

  testWidgets('finishing the setup clears a session from an earlier server', (tester) async {
    final app = await openApp(tester, session: loggedIn());

    expect(find.byType(SetupScreen), findsOneWidget);

    await connect(tester, 'https://musik.meinserver.at/');
    await tester.tap(find.widgetWithText(TextButton, 'Weiter'));
    await tester.pumpAndSettle();

    expect(app.session.isLoggedIn, false);
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  // A stored server is the second start: the setup does not run again.
  testWidgets('the second start goes straight to the login of the saved server', (tester) async {
    await openApp(tester, settings: SettingsStore()..serverBase = 'https://musik.meinserver.at');

    expect(find.byType(SetupScreen), findsNothing);
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('a second start that is still logged in opens the library directly', (tester) async {
    await openApp(
      tester,
      settings: SettingsStore()..serverBase = 'https://musik.meinserver.at',
      session: loggedIn(),
      // The library asks who the session belongs to.
      adapter: StubAdapter(200, {'id': 7.0, 'username': 'lukas'}),
    );

    expect(find.byType(SetupScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('changing the server stores it, clears the old session and asks to log in again', (tester) async {
    // The home screen's session check is answered first, then the check of the new address.
    final app = await openApp(
      tester,
      settings: SettingsStore()..serverBase = 'https://musik.meinserver.at',
      session: loggedIn(),
      adapter: (StubAdapter(0, {})
        ..queue.addAll([
          (200, {'id': 7.0, 'username': 'lukas'}),
          (401, {'error': 'authorization header with a Bearer token is missing'}),
        ])),
    );

    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Konto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);

    await connect(tester, 'https://musik.anders.at/', 'Server ändern');

    expect(app.settings.serverBase, 'https://musik.anders.at');
    expect(app.session.isLoggedIn, false);
    expect(find.byType(AuthScreen), findsOneWidget);
  });
}
