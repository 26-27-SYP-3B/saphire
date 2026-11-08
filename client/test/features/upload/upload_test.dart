import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';

import '../../support/stub_adapter.dart';

// Numbers as they arrive on the web: as doubles, so the model has to read them
// through num.
const uploadAnswer = {
  'id': 4.0,
  'uploaded_by': 'lukas',
  'title': 'song.mp3',
  'stored_name': '18cfd7db41d243d98cc87c4ab33dded6.mp3',
  'size': 1500000.0,
  'content_type': 'audio/mpeg',
  'uploaded_at': 1793974311.0,
};

/// A session that is still valid, because the upload only accepts one.
SessionStore loggedIn() =>
    SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

void main() {
  test('reads the upload answer as a track', () async {
    final repository = UploadRepository(Dio()..httpClientAdapter = StubAdapter(201, uploadAnswer), loggedIn());

    final track = await repository.upload(filename: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3]));

    expect(track.id, 4);
    expect(track.uploadedBy, 'lukas');
    expect(track.title, 'song.mp3');
    expect(track.storedName, '18cfd7db41d243d98cc87c4ab33dded6.mp3');
    expect(track.size, 1500000);
    expect(track.contentType, 'audio/mpeg');
    expect(track.uploadedAt, 1793974311);
  });

  // The server only accepts a part named "file", so the field name is part of
  // the contract, not of the implementation.
  test('sends the file as the field "file" with the session token', () async {
    final adapter = StubAdapter(201, uploadAnswer);
    await UploadRepository(Dio()..httpClientAdapter = adapter, loggedIn())
        .upload(filename: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3]));

    expect(adapter.lastOptions?.method, 'POST');
    expect(adapter.lastOptions?.uri.path, '/api/music/upload');
    expect(adapter.lastOptions?.headers['Authorization'], 'Bearer ${'a' * 64}');
    expect(adapter.lastBody, contains('name="file"'));
    expect(adapter.lastBody, contains('filename="song.mp3"'));
  });

  test('reports how much of the file was sent, so the page can show a percent', () async {
    final adapter = StubAdapter(201, uploadAnswer);
    final seen = <List<int>>[];

    await UploadRepository(Dio()..httpClientAdapter = adapter, loggedIn()).upload(
      filename: 'song.mp3',
      bytes: Uint8List.fromList([1, 2, 3]),
      onProgress: (count, total) => seen.add([count, total]),
    );

    // The page can only show a percent while the file is being written, so the
    // counts have to arrive before the answer.
    expect(seen, isNotEmpty);
    expect(seen.first.first, greaterThan(0));
    expect(seen.last.first, seen.last[1]);
  });

  test('the message of the server is passed on', () async {
    final repository = UploadRepository(
      Dio()..httpClientAdapter = StubAdapter(401, {'error': 'session is not valid or expired'}),
      SessionStore(),
    );

    expect(
      () => repository.upload(filename: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3])),
      throwsA(isA<UploadException>().having(
        (error) => error.message,
        'message',
        'session is not valid or expired',
      )),
    );
  });

  test('names the retry time when the server sends Retry-After', () async {
    final repository = UploadRepository(
      Dio()
        ..httpClientAdapter = StubAdapter(
          429,
          {'error': 'too many uploads from this address, try again later'},
          headers: {'retry-after': ['30']},
        ),
      loggedIn(),
    );

    expect(
      () => repository.upload(filename: 'song.mp3', bytes: Uint8List.fromList([1, 2, 3])),
      throwsA(isA<UploadException>().having(
        (error) => error.message,
        'message',
        'too many uploads from this address, try again later (Erneut versuchen in 30 s).',
      )),
    );
  });
}
