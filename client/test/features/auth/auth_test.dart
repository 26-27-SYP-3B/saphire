import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/app.dart';
import 'package:saphire_client/app/router.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/auth/domain/user.dart';
import 'package:saphire_client/features/auth/presentation/auth_screen.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

/// Repository that never calls the server, so the form can be tested on its own.
/// A successful login fills the session store like the real one would.
class FakeRepository extends AuthRepository {
  FakeRepository(this.failureMessage) : super(Dio(), SessionStore());

  final String? failureMessage;

  @override
  Future<User> register({required String username, required String password}) {
    final message = failureMessage;
    if (message != null) throw AuthException(message);
    return Future.value(User(id: 7, username: username));
  }

  @override
  Future<void> login({required String username, required String password}) {
    final message = failureMessage;
    if (message != null) throw AuthException(message);
    session.save('f' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);
    return Future.value();
  }

  // The home screen asks who the session belongs to, so the answer has to come
  // from here instead of from the network.
  @override
  Future<User> currentSession() => Future.value(User(id: 7, username: 'lukas'));
}

Future<void> openLogin(WidgetTester tester, AuthRepository repository) async {
  // Nothing uploads in these tests, the start page only needs the repository to
  // exist.
  // The feature pages are part of the app, so a test that only checks the guard still
  // needs their pieces to exist.
  final wiring = Wiring(repository.session);
  await tester.pumpWidget(
    SaphireApp(
      repository: repository,
      uploads: UploadRepository(Dio(), repository.session),
      library: wiring.library,
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: repository.session,
      settings: withServer(),
      dio: Dio(),
    ),
  );
}

Future<void> openRegister(WidgetTester tester, AuthRepository repository) async {
  await openLogin(tester, repository);
  await tester.tap(find.widgetWithText(TextButton, 'Registrieren'));
  await tester.pumpAndSettle();
}

Future<void> fillForm(WidgetTester tester, {String username = 'lukas', String password = 'geheim123'}) async {
  await tester.enterText(find.byType(TextFormField).first, username);
  await tester.enterText(find.byType(TextFormField).last, password);
}

Future<void> submit(WidgetTester tester, String buttonLabel) async {
  await tester.tap(find.widgetWithText(FilledButton, buttonLabel));
  await tester.pumpAndSettle();
}

void main() {
  test('reads the answer of the server as a user', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(201, {'id': 7, 'username': 'lukas'});

    final user = await AuthRepository(dio, SessionStore()).register(username: 'lukas', password: 'geheim123');

    expect(user.id, 7);
    expect(user.username, 'lukas');
  });

  test('passes the error message of the server on', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(429, {'error': 'too many registrations from this address'});

    expect(
      () => AuthRepository(dio, SessionStore()).register(username: 'lukas', password: 'geheim123'),
      throwsA(isA<AuthException>().having(
        (error) => error.message,
        'message',
        'too many registrations from this address',
      )),
    );
  });

  test('names the retry time when the server sends Retry-After', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        429,
        {'error': 'too many logins from this address, try again later'},
        headers: {'retry-after': ['60']},
      );

    expect(
      () => AuthRepository(dio, SessionStore()).login(username: 'lukas', password: 'geheim123'),
      throwsA(isA<AuthException>().having(
        (error) => error.message,
        'message',
        'too many logins from this address, try again later (Erneut versuchen in 60 s).',
      )),
    );
  });

  test('a login stores the session, the store is empty before', () async {
    final store = SessionStore();
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(200, {'token': 'a' * 64, 'expires_at': 2000000000});

    expect(store.isLoggedIn, false);
    await AuthRepository(dio, store).login(username: 'lukas', password: 'geheim123');

    expect(store.isLoggedIn, true);
    expect(store.token, 'a' * 64);
  });

  test('the session check carries the stored token as a Bearer header', () async {
    final store = SessionStore()..save('b' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);
    final adapter = StubAdapter(200, {'id': 7, 'username': 'lukas'});
    final repository = AuthRepository(Dio()..httpClientAdapter = adapter, store);

    final user = await repository.currentSession();

    expect(user.id, 7);
    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer ${'b' * 64}');
  });

  testWidgets('registering logs in and goes to the home screen', (tester) async {
    final repository = FakeRepository(null);
    await openRegister(tester, repository);

    await fillForm(tester);
    await submit(tester, 'Registrieren');

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(repository.session.isLoggedIn, true);
  });

  testWidgets('logging in calls the server and goes to the home screen', (tester) async {
    final repository = FakeRepository(null);
    await openLogin(tester, repository);

    await fillForm(tester);
    await submit(tester, 'Anmelden');

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(repository.session.isLoggedIn, true);
  });

  testWidgets('the profile menu logs out and goes back to the login screen', (tester) async {
    final repository = FakeRepository(null);
    await openLogin(tester, repository);
    await fillForm(tester);
    await submit(tester, 'Anmelden');

    await tester.tap(find.byTooltip('Konto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Abmelden'));
    await tester.pumpAndSettle();

    expect(repository.session.isLoggedIn, false);
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  // A token kept from the last run opens the home screen without the form.
  testWidgets('a saved session skips the login screen', (tester) async {
    final repository = FakeRepository(null);
    repository.session.save('f' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

    await openLogin(tester, repository);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  // Without a session there is nothing to show on the home screen, so a direct
  // navigation stays on the login.
  testWidgets('the home screen is guarded while no session exists', (tester) async {
    final repository = FakeRepository(null);
    final wiring = Wiring(repository.session);
    final router = buildRouter(
      auth: repository,
      uploads: UploadRepository(Dio(), repository.session),
      library: wiring.library,
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: repository.session,
      settings: withServer(),
      dio: Dio(),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    router.go('/home');
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);

    await repository.login(username: 'lukas', password: 'geheim123');
    router.go('/home');
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // Local mode has no account, so the guard must let the app reach the home screen. The
  // button on the login form is what starts it and what the next start reads.
  testWidgets('the choice to run without a server opens the home screen', (tester) async {
    final repository = FakeRepository(null);
    final settings = withServer();
    final wiring = Wiring(repository.session);
    addTearDown(wiring.dispose);

    final router = buildRouter(
      auth: repository,
      uploads: UploadRepository(Dio(), repository.session),
      library: wiring.library,
      playlists: wiring.playlists,
      queues: wiring.queues,
      queue: wiring.queue,
      player: wiring.player,
      session: repository.session,
      settings: settings,
      dio: Dio(),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ohne Server fortfahren'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(settings.localMode, true);
  });

  testWidgets('an error from the server shows below the fields', (tester) async {
    await openRegister(tester, FakeRepository('username is not available'));

    await fillForm(tester);
    await submit(tester, 'Registrieren');

    expect(find.text('username is not available'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  // The form checks the same limits as the server, so a short password never
  // leaves the phone.
  testWidgets('a short password is stopped before the request', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    await fillForm(tester, password: 'short');
    await submit(tester, 'Anmelden');

    expect(find.text('Passwort: mindestens 8 Zeichen'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  // The server counts UTF-8 bytes, so 37 ä characters (74 bytes) are too long
  // even though they are under 72 characters.
  testWidgets('a password that is too long in bytes is stopped too', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    await fillForm(tester, password: 'ä' * 37);
    await submit(tester, 'Anmelden');

    expect(find.text('Passwort: höchstens 72 Bytes'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('a control character in the password is stopped too', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    // Not a line feed: a single-line TextField filters those out of typed
    // input, a tab reaches the validator like the server would see it.
    await fillForm(tester, password: 'geheim123\t');
    await submit(tester, 'Anmelden');

    expect(find.text('Passwort: keine Kontrollzeichen'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('a username the server would reject is stopped too', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    await fillForm(tester, username: 'lu kas');
    await submit(tester, 'Anmelden');

    expect(find.text('Benutzername: nur Buchstaben, Zahlen, Unterstrich, Punkt und Bindestrich'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
