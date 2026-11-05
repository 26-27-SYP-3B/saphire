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
  Future<User> register({required String name, required String email}) {
    final message = failureMessage;
    if (message != null) throw AuthException(message);
    return Future.value(User(id: 7, name: name, email: email));
  }
}

void main() {
  test('reads the answer of the server as a user', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(
        201,
        {'id': 7, 'name': 'Lukas', 'email': 'lukas@example.at'},
      );

    final user = await AuthRepository(dio).register(
      name: 'Lukas',
      email: 'lukas@example.at',
    );

    expect(user.id, 7);
    expect(user.email, 'lukas@example.at');
  });

  test('passes the error message of the server on', () async {
    final dio = Dio()
      ..httpClientAdapter = StubAdapter(409, {'error': 'email is already registered'});

    expect(
      () => AuthRepository(dio).register(name: 'Lukas', email: 'lukas@example.at'),
      throwsA(isA<AuthException>().having(
        (error) => error.message,
        'message',
        'email is already registered',
      )),
    );
  });

  testWidgets('shows the server error below the form', (tester) async {
    await tester.pumpWidget(
      SaphireApp(repository: FakeRepository('Server is not reachable at http://localhost:8080.')),
    );

    await tester.enterText(find.byType(TextFormField).first, 'Lukas');
    await tester.enterText(find.byType(TextFormField).last, 'lukas@example.at');
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();

    expect(find.text('Server is not reachable at http://localhost:8080.'), findsOneWidget);
  });

  testWidgets('shows the created account', (tester) async {
    await tester.pumpWidget(SaphireApp(repository: FakeRepository(null)));

    await tester.enterText(find.byType(TextFormField).first, 'Lukas');
    await tester.enterText(find.byType(TextFormField).last, 'lukas@example.at');
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();

    expect(find.text('Account created: Lukas (#7)'), findsOneWidget);
  });
}
