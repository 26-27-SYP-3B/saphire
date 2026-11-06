import 'package:dio/dio.dart';

import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/user.dart';

/// Raised when an auth call fails: the message from the server, or our own
/// explanation when the server was not reachable.
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Calls the auth endpoints of the server.
class AuthRepository {
  AuthRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  /// POST /api/register, which creates the user and returns it including its id.
  Future<User> register({required String username, required String password}) async {
    Response response;
    try {
      response = await _dio.post('$apiBaseUrl/api/register', data: {
        'username': username,
        'password': password,
      });
    } on DioException catch (error) {
      throw AuthException(errorMessageFor(error));
    }

    return User.fromJson(response.data as Map<String, dynamic>);
  }

  /// POST /api/login. The token in the answer is the only time the client ever
  /// sees it, the server stores only its hash, so we keep it here for the
  /// session check and save nothing else.
  Future<void> login({required String username, required String password}) async {
    Response response;
    try {
      response = await _dio.post('$apiBaseUrl/api/login', data: {
        'username': username,
        'password': password,
      });
    } on DioException catch (error) {
      throw AuthException(errorMessageFor(error));
    }

    final data = response.data as Map<String, dynamic>;
    // JSON numbers arrive as double on the web, so read them as num.
    session.save(data['token'] as String, (data['expires_at'] as num).toInt());
  }

  /// GET /api/session with the stored token: how the app checks that the
  /// session is still valid.
  Future<User> currentSession() async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/session',
        options: Options(headers: {'Authorization': 'Bearer ${session.token}'}),
      );
      return User.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw AuthException(errorMessageFor(error));
    }
  }

  void logout() => session.clear();

  String errorMessageFor(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['error'] is String) {
      final message = data['error'] as String;
      // The server sends Retry-After with a 429; say when the next try makes sense.
      final retryAfter = error.response?.headers.value('retry-after');
      if (retryAfter != null) {
        return '$message (Erneut versuchen in $retryAfter s).';
      }
      return message;
    }
    if (error.type == DioExceptionType.connectionError) {
      return 'Server ist nicht erreichbar unter $apiBaseUrl.';
    }
    return 'Anfrage fehlgeschlagen (${error.response?.statusCode ?? 'unbekannter Status'}).';
  }
}
