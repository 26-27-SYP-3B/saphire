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

      // The documented shape is a list of objects. An answer that is not one is not this
      // API, and it has to be named here: a failed cast would escape the page, which then
      // waits on a list that never arrives.
      final answer = response.data;
      if (answer is! List) {
        throw LibraryException('die Antwort ist keine Liste von Liedern');
      }

      final entries = <LibraryEntry>[];
      for (final row in answer) {
        if (row is! Map<String, dynamic>) {
          throw LibraryException('ein Eintrag ist kein Objekt mit id und Titel');
        }
        entries.add(LibraryEntry.fromJson(row));
      }
      return entries;
    } on DioException catch (error) {
      throw LibraryException(serverErrorMessage(error));
    }
  }
}
