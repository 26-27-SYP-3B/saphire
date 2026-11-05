import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/app.dart';
import 'package:saphire_client/features/auth/data/auth_repository.dart';
import 'package:saphire_client/features/auth/domain/user.dart';

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

Future<void> fillRegisterForm(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).first, 'lukas');
  await tester.enterText(find.byType(TextFormField).at(1), 'lukas@example.at');
  await tester.enterText(find.byType(TextFormField).last, 'geheim123');
}

/// The login form has two fields: the identity and the password.
Future<void> fillLoginForm(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).first, 'lukas');
  await tester.enterText(find.byType(TextFormField).last, 'geheim123');
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

  testWidgets('registering shows the created account', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));
    await tester.tap(find.widgetWithText(TextButton, 'Registrieren'));
    await tester.pumpAndSettle();

    await fillRegisterForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Registrieren'));
    await tester.pumpAndSettle();

    expect(find.text('Konto erstellt als lukas (#7)'), findsOneWidget);
  });

  testWidgets('logging in with the username shows the account', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));

    await fillLoginForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Angemeldet als lukas (#7)'), findsOneWidget);
  });

  // The login accepts a username or an address, so the same form is used with an
  // address in the first field.
  testWidgets('logging in with the address shows the account', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));

    await tester.enterText(find.byType(TextFormField).first, 'lukas@example.at');
    await tester.enterText(find.byType(TextFormField).last, 'geheim123');
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Angemeldet als lukas@example.at (#7)'), findsOneWidget);
  });

  testWidgets('an error from the server shows below the fields', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository('login or password is wrong')));

    await fillLoginForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('login or password is wrong'), findsOneWidget);
  });

  // The form checks the same limits as the server, so a short password never
  // leaves the phone.
  testWidgets('a short password is stopped before the request', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));

    await tester.enterText(find.byType(TextFormField).first, 'lukas');
    await tester.enterText(find.byType(TextFormField).last, 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Passwort: mindestens 8 Zeichen'), findsOneWidget);
    expect(find.text('Angemeldet als lukas (#7)'), findsNothing);
  });
}
