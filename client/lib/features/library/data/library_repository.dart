import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/library_entry.dart';

/// Raised when a library call fails. The message is the server's own, so what the page
/// shows is what api-docs.md describes.
class LibraryException implements Exception {
  LibraryException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Reads the shared library. Only a logged-in user may read it, so the stored session
/// token goes as a Bearer header, like every other call.
///
/// There is no search endpoint (see api-docs.md, Upcoming), so this gives the whole
/// library and the page filters what it got. shortcut: no pagination and no server-side
/// search, upgrade when GET /api/music has one.
class LibraryRepository {
  LibraryRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  // The header is only built when there is a token. "Bearer null" would be answered as an
  // unknown session, and the user would read a message about a token they never sent.
  Map<String, String> get _headers {
    final token = session.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  /// The library, ordered by id as the server answers it. An empty library answers [],
  /// never null.
  Future<List<LibraryEntry>> list() async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/music',
        options: Options(headers: _headers),
      );
      return (response.data as List? ?? const [])
          .map((entry) => LibraryEntry.fromJson(entry as Map<String, dynamic>))
          .toList();
    } on DioException catch (error) {
      throw LibraryException(serverErrorMessage(error));
    }
  }
}
