import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/queue.dart';

/// Raised when a queue call fails.
class QueueException implements Exception {
  QueueException(this.message, [this.statusCode]);

  final String message;

  /// What the server answered with. Only a 401 says the token is gone, so a page may drop
  /// the session on that status alone — a 429 or a 400 is not a lost login.
  final int? statusCode;

  @override
  String toString() => message;
}

/// Calls the queue endpoints. The queue is stored on the server, so this is the source
/// of the list; the mirror in domain/queue.dart only follows what this returns.
class QueueRepository {
  QueueRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  // The header is only built when there is a token, the same rule the player follows: a
  // "Bearer null" request is answered as an unknown session, not as a missing header.
  Map<String, String> get _headers {
    final token = session.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  /// Fills the queue from a source and returns the queue as the server now has it.
  /// Filling replaces the list — it does not add to it — which is what starting a
  /// playlist means.
  Future<List<QueueEntry>> fill(QueueSource source) async {
    try {
      final response = await _dio.post(
        '$apiBaseUrl/api/queue',
        data: source.toJson(),
        options: Options(headers: _headers),
      );
      return _entries(response.data);
    } on DioException catch (error) {
      throw QueueException(serverErrorMessage(error), error.response?.statusCode);
    }
  }

  /// The queue as the server keeps it. Another device may have changed it since the last
  /// read, so a player that wants the current list reads it again.
  Future<List<QueueEntry>> read() async {
    try {
      final response = await _dio.get('$apiBaseUrl/api/queue', options: Options(headers: _headers));
      return _entries(response.data);
    } on DioException catch (error) {
      throw QueueException(serverErrorMessage(error), error.response?.statusCode);
    }
  }

  Future<QueueEntry> append(int trackId) async {
    try {
      final response = await _dio.post(
        '$apiBaseUrl/api/queue/songs',
        data: {'track_id': trackId},
        options: Options(headers: _headers),
      );
      return QueueEntry.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw QueueException(serverErrorMessage(error), error.response?.statusCode);
    }
  }

  /// Removes one 1-based position. The rest are renumbered, so the positions the page
  /// shows after this are the ones the server answered with.
  Future<void> remove(int position) async {
    try {
      await _dio.delete('$apiBaseUrl/api/queue/$position', options: Options(headers: _headers));
    } on DioException catch (error) {
      throw QueueException(serverErrorMessage(error), error.response?.statusCode);
    }
  }

  Future<void> clear() async {
    try {
      await _dio.delete('$apiBaseUrl/api/queue', options: Options(headers: _headers));
    } on DioException catch (error) {
      throw QueueException(serverErrorMessage(error), error.response?.statusCode);
    }
  }

  // An empty queue answers [], never null.
  List<QueueEntry> _entries(Object? data) => (data as List? ?? const [])
      .map((entry) => QueueEntry.fromJson(entry as Map<String, dynamic>))
      .toList();
}
