import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/library_entry.dart';

/// Raised when the library cannot be read.
class LibraryException implements Exception {
  LibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the shared library. The list is the same for every logged-in user, so a token
/// is all this needs; there is no per-user path on the server.
class LibraryRepository {
  LibraryRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  /// GET /api/music. The server answers [] for an empty library, never null, so this
  /// is always a list and the page does not have to tell the two apart.
  Future<List<LibraryEntry>> list() async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/music',
        options: Options(headers: {'Authorization': 'Bearer ${session.token}'}),
      );
      final rows = response.data as List<dynamic>;
      return [for (final row in rows) LibraryEntry.fromJson(row as Map<String, dynamic>)];
    } on DioException catch (error) {
      throw LibraryException(serverErrorMessage(error));
    }
  }
}
