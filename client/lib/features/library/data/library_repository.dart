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

/// Reads the library. GET /api/music is only planned on the server
/// (api-docs.md, Upcoming), so this reads exactly the shape that is documented:
/// every song as its id and its title.
class LibraryRepository {
  LibraryRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  /// An empty library answers [], so this is an empty list and never null.
  Future<List<Track>> list() async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/music',
        options: Options(headers: {'Authorization': 'Bearer ${session.token}'}),
      );

      final data = response.data;
      if (data is! List) return [];
      return [for (final row in data) Track.fromJson(row as Map<String, dynamic>)];
    } on DioException catch (error) {
      throw LibraryException(serverErrorMessage(error));
    }
  }
}
