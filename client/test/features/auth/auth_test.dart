import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/app.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/auth/domain/user.dart';
import 'package:saphire_client/features/home/presentation/home_screen.dart';

/// Adapter that returns one fixed answer instead of going to the network.
class StubAdapter implements HttpClientAdapter {
  StubAdapter(this.statusCode, this.body);

  final int statusCode;
  final Object body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      jsonEncode(body),
      statusCode,
      headers: {HttpHeaders.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Repository that never calls the server, so the form can be tested on its own.
class FakeRepository extends AuthRepository {
  FakeRepository(this.failureMessage) : super(Dio());

  final String? failureMessage;

  @override
  Future<User> register({required String username, required String email, required String password}) {
    return _answer(username);
  }

  @override
  Future<User> login({required String login, required String password}) {
    return _answer(login);
  }

  Future<User> _answer(String login) {
    final message = failureMessage;
    if (message != null) throw AuthException(message);
    return Future.value(User(id: 7, username: login, email: 'lukas@example.at'));
  }
}

Future<void> openLogin(WidgetTester tester, AuthRepository repository) async {
  await tester.pumpWidget(SaphireApp(repository: repository));
}

Future<void> openRegister(WidgetTester tester, AuthRepository repository) async {
  await openLogin(tester, repository);
  await tester.tap(find.widgetWithText(TextButton, 'Registrieren'));
  await tester.pumpAndSettle();
}

/// The login form has two fields: the identity and the password.
Future<void> fillLoginForm(WidgetTester tester, String identity) async {
  await tester.enterText(find.byType(TextFormField).first, identity);
  await tester.enterText(find.byType(TextFormField).last, 'geheim123');
  await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
  await tester.pumpAndSettle();
}

void main() {
  test('reads the answer of the server as a user', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        201,
        {'id': 7, 'username': 'lukas', 'email': 'lukas@example.at'},
      );

    final user = await AuthRepository(dio).register(
      username: 'lukas',
      email: 'lukas@example.at',
      password: 'geheim123',
    );

    expect(user.id, 7);
    expect(user.username, 'lukas');
  });

  test('passes the error message of the server on', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(401, {'error': 'login or password is wrong'});

    expect(
      () => AuthRepository(dio).login(login: 'lukas', password: 'geheim123'),
      throwsA(isA<AuthException>().having(
        (error) => error.message,
        'message',
        'login or password is wrong',
      )),
    );
  });

  testWidgets('registering goes to the empty home screen', (tester) async {
    await openRegister(tester, FakeRepository(null));

    await tester.enterText(find.byType(TextFormField).first, 'lukas');
    await tester.enterText(find.byType(TextFormField).at(1), 'lukas@example.at');
    await tester.enterText(find.byType(TextFormField).last, 'geheim123');
    await tester.tap(find.widgetWithText(FilledButton, 'Registrieren'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('logging in with the username goes to the home screen', (tester) async {
    await openLogin(tester, FakeRepository(null));
    await fillLoginForm(tester, 'lukas');

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // The first field takes a username or an address, so an address has to pass the
  // check without being treated as a username.
  testWidgets('logging in with an address goes to the home screen', (tester) async {
    await openLogin(tester, FakeRepository(null));
    await fillLoginForm(tester, 'lukas@example.at');

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Das ist keine Adresse'), findsNothing);
  });

  testWidgets('an error from the server shows below the fields', (tester) async {
    await openLogin(tester, FakeRepository('login or password is wrong'));
    await fillLoginForm(tester, 'lukas');

    expect(find.text('login or password is wrong'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  // The form checks the same limits as the server, so a short password never
  // leaves the phone.
  testWidgets('a short password is stopped before the request', (tester) async {
    await openLogin(tester, FakeRepository(null));

    await tester.enterText(find.byType(TextFormField).first, 'lukas');
    await tester.enterText(find.byType(TextFormField).last, 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Passwort: mindestens 8 Zeichen'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
