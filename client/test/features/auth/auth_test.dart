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
  Future<User> register({required String username, required String password}) {
    final message = failureMessage;
    if (message != null) throw AuthException(message);
    return Future.value(User(id: 7, username: username));
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

Future<void> fillForm(WidgetTester tester) async {
  await tester.enterText(find.byType(TextFormField).first, 'lukas');
  await tester.enterText(find.byType(TextFormField).last, 'geheim123');
}

Future<void> submit(WidgetTester tester, String buttonLabel) async {
  await tester.tap(find.widgetWithText(FilledButton, buttonLabel));
  await tester.pumpAndSettle();
}

void main() {
  test('reads the answer of the server as a user', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(201, {'id': 7, 'username': 'lukas'});

    final user = await AuthRepository(dio).register(username: 'lukas', password: 'geheim123');

    expect(user.id, 7);
    expect(user.username, 'lukas');
  });

  test('passes the error message of the server on', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(429, {'error': 'too many registrations from this address'});

    expect(
      () => AuthRepository(dio).register(username: 'lukas', password: 'geheim123'),
      throwsA(isA<AuthException>().having(
        (error) => error.message,
        'message',
        'too many registrations from this address',
      )),
    );
  });

  testWidgets('registering goes to the home screen', (tester) async {
    await openRegister(tester, FakeRepository(null));

    await fillForm(tester);
    await submit(tester, 'Registrieren');

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // The login has no endpoint, so it must not send anything: a repository that
  // would fail here proves that nothing was called.
  testWidgets('logging in goes to the home screen without a request', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    await fillForm(tester);
    await submit(tester, 'Anmelden');

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('darf hier nicht aufgerufen werden'), findsNothing);
  });

  testWidgets('an error from the server shows below the fields', (tester) async {
    await openRegister(tester, FakeRepository('username already taken'));

    await fillForm(tester);
    await submit(tester, 'Registrieren');

    expect(find.text('username already taken'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  // The form checks the same limits as the server, so a short password never
  // leaves the phone.
  testWidgets('a short password is stopped before the request', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    await tester.enterText(find.byType(TextFormField).first, 'lukas');
    await tester.enterText(find.byType(TextFormField).last, 'short');
    await submit(tester, 'Anmelden');

    expect(find.text('Passwort: mindestens 8 Zeichen'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('a username the server would reject is stopped too', (tester) async {
    await openLogin(tester, FakeRepository('darf hier nicht aufgerufen werden'));

    await tester.enterText(find.byType(TextFormField).first, 'lu kas');
    await tester.enterText(find.byType(TextFormField).last, 'geheim123');
    await submit(tester, 'Anmelden');

    expect(find.text('Benutzername: nur Buchstaben, Zahlen, Unterstrich, Punkt und Bindestrich'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
