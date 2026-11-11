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

  // Each test starts from the launch default rather than from whatever the previous
  // test saved; a stored server is applied the way SettingsStore applies it.
  if (store.serverBase == null) {
    apiBaseUrl = launchBase;
  } else {
    await store.save(server: store.serverBase!);
  }

  final wiring = Wiring(current);
  // The app's State.dispose releases the player when the test tears the tree down, the
  // same way a run ends. Disposing it here as well made the test hang (tried with
  // addTearDown(wiring.dispose)), so this helper leaves it to the app.

  await tester.pumpWidget(
    SaphireApp(
      repository: AuthRepository(dio, current),
      uploads: UploadRepository(dio, current),
      library: wiring.library,
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

  // The choice the start asks for: the way without a server sits below the address field
  // and needs no request, because there is no server to ask.
  testWidgets('the first start offers the way without a server and remembers it', (tester) async {
    final app = await openApp(tester);

    expect(find.text('Weiter ohne Server'), findsOneWidget);

    await tester.tap(find.text('Weiter ohne Server'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(app.settings.localMode, true);
    expect(app.adapter.requests, isEmpty);

    // The next start reads the same store, so it does not ask again.
    await openApp(tester, settings: app.settings);
    expect(find.byType(SetupScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // A phone with a large system font and a navigation bar leaves little room. The choice
  // has to stay visible and tappable instead of sitting under the navigation bar, where
  // nothing can scroll it into view.
  testWidgets('the way without a server stays reachable on a small phone', (tester) async {
    final app = await openApp(tester);
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1.0
      ..padding = const FakeViewPadding(top: 24, bottom: 48);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();

    final button = find.widgetWithText(TextButton, 'Weiter ohne Server');
    expect(button, findsOneWidget);

    // 640 - 48 is where the app area ends; the button's last pixel has to be above it.
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(640 - 48));

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(app.settings.localMode, true);
  });

  // A session belongs to a server, and this start uses none.
  testWidgets('choosing without a server drops a session from an earlier server', (tester) async {
    final app = await openApp(tester, session: loggedIn());

    await tester.tap(find.text('Weiter ohne Server'));
    await tester.pumpAndSettle();

    expect(app.session.isLoggedIn, false);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // The guard is only read when a route is resolved, so this has to run inside a
  // widget: a router that was never built has no current location to redirect.
  testWidgets('without a stored server even /login leads to the setup', (tester) async {
    final settings = SettingsStore();
    final session = SessionStore();
    final dio = Dio()..httpClientAdapter = saphireServer();
    final wiring = Wiring(session);
    addTearDown(wiring.dispose);

    final router = buildRouter(
      auth: AuthRepository(dio, session),
      uploads: UploadRepository(dio, session),
      library: wiring.library,
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: session,
      settings: settings,
      dio: dio,
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.go('/login');
    await tester.pumpAndSettle();

    expect(router.routerDelegate.currentConfiguration.uri.path, '/setup');
  });

  testWidgets('a reachable address is confirmed and leads straight to the login', (tester) async {
    final app = await openApp(tester);

    await connect(tester, 'https://musik.meinserver.at/');

    // The check goes to the typed host, not to the launch default.
    expect(app.adapter.lastOptions?.uri.host, 'musik.meinserver.at');
    expect(app.adapter.lastOptions?.uri.path, '/api/session');

    // One button, no second step: the confirmed address is stored and the login follows.
    expect(app.settings.serverBase, 'https://musik.meinserver.at');
    expect(find.byType(AuthScreen), findsOneWidget);
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

    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('an address with a path is refused before any request', (tester) async {
    final app = await openApp(tester);

    await connect(tester, 'https://musik.meinserver.at/api');

    expect(find.text('Server-Adresse: http:// oder https:// mit Host'), findsOneWidget);
    expect(app.adapter.requests, isEmpty);
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

  // The same address is nothing to change: no request, and the session stays.
  testWidgets('the settings page with the address it already has keeps the session', (tester) async {
    final app = await openApp(
      tester,
      settings: SettingsStore()..serverBase = 'https://musik.meinserver.at',
      session: loggedIn(),
      // The library asks who the session belongs to, and the page asks for nothing.
      adapter: StubAdapter(200, {'id': 7.0, 'username': 'lukas'}),
    );

    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Konto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);

    await connect(tester, 'https://musik.meinserver.at', 'Server ändern');

    // Both calls are the library's session check with the token. The page sent no check
    // of the address, which is what keeping the address means.
    expect(app.adapter.requests.where((r) => r.headers['Authorization'] == null), isEmpty);
    expect(app.session.isLoggedIn, true);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // A server chosen after the start without one ends local mode: otherwise the next start
  // would skip the login for a server that has accounts.
  testWidgets('choosing a server after starting without one leaves local mode', (tester) async {
    final app = await openApp(tester, settings: SettingsStore()..localMode = true);

    await tester.tap(find.byTooltip('Konto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Einstellungen'));
    await tester.pumpAndSettle();
    await connect(tester, 'https://musik.anders.at/', 'Server ändern');

    expect(app.settings.serverBase, 'https://musik.anders.at');
    expect(app.settings.localMode, false);
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  // Without a stored server the login has no address; sending the user there would use
  // the launch default instead of asking.
  testWidgets('from local mode without a server, connecting leads back to the setup', (tester) async {
    await openApp(tester, settings: SettingsStore()..localMode = true);

    await tester.tap(find.byTooltip('Konto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mit Server verbinden'));
    await tester.pumpAndSettle();

    expect(find.byType(SetupScreen), findsOneWidget);
  });
}
