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
    return _answer(username, email);
  }

  @override
  Future<User> login({required String username, required String email, required String password}) {
    return _answer(username, email);
  }

  Future<User> _answer(String username, String email) {
    final message = failureMessage;
    if (message != null) throw AuthException(message);
    return Future.value(User(id: 7, username: username, email: email));
  }
}

Future<void> openForm(WidgetTester tester, AuthRepository repository, String linkLabel) async {
  await tester.pumpWidget(SaphireApp(repository: repository));
  await tester.tap(find.widgetWithText(TextButton, linkLabel));
  await tester.pumpAndSettle();
}

Future<void> fillForm(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).first, 'lukas');
  await tester.enterText(find.byType(TextFormField).at(1), 'lukas@example.at');
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
      ..httpClientAdapter = StubAdapter(409, {'error': 'username or email is already registered'});

    expect(
      () => AuthRepository(dio).login(
        username: 'lukas',
        email: 'lukas@example.at',
        password: 'geheim123',
      ),
      throwsA(isA<AuthException>().having(
        (error) => error.message,
        'message',
        'username or email is already registered',
      )),
    );
  });

  testWidgets('registering shows the created account', (tester) async {
    await openForm(tester, FakeRepository(null), 'Registrieren');

    await fillForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Registrieren'));
    await tester.pumpAndSettle();

    expect(find.text('Konto erstellt als lukas (#7)'), findsOneWidget);
  });

  testWidgets('logging in shows the account', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));

    await fillForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Angemeldet als lukas (#7)'), findsOneWidget);
  });

  testWidgets('an error from the server shows below the fields', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository('username, email or password is wrong')));

    await fillForm(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('username, email or password is wrong'), findsOneWidget);
  });

  // The form checks the same limits as the server, so a short password never
  // leaves the phone.
  testWidgets('a short password is stopped before the request', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));

    await tester.enterText(find.byType(TextFormField).first, 'lukas');
    await tester.enterText(find.byType(TextFormField).at(1), 'lukas@example.at');
    await tester.enterText(find.byType(TextFormField).last, 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();

    expect(find.text('Passwort: mindestens 8 Zeichen'), findsOneWidget);
    expect(find.text('Angemeldet als lukas (#7)'), findsNothing);
  });
}
