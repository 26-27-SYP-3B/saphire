import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../../upload/domain/track.dart';

/// Raised when the library cannot be read.
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
  /// so this is an empty list and never null. An answer that is not that list is an
  /// error, not an empty library: the page cannot say what a library holds before it has
  /// an answer.
  Future<List<Track>> list() async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/music',
        options: Options(headers: _headers),
      );

      final data = response.data;
      if (data is! List) throw LibraryException(unreadableAnswer);
      return [for (final row in data) Track.fromJson(row as Map<String, dynamic>)];
    } on DioException catch (error) {
      throw LibraryException(serverErrorMessage(error));
    } on TypeError {
      // A row that is not the documented object throws here rather than showing half a song.
      throw LibraryException(unreadableAnswer);
    }
  }
}
