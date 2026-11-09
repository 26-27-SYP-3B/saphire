import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/user.dart';

/// Raised when an auth call fails: the message from the server, or our own
/// explanation when the server was not reachable.
class AuthException implements Exception {
  AuthException(this.message, {this.offline = false});

  final String message;

  /// True when the server could not be reached at all. Only this is "offline":
  /// a server that answers with an error is reachable, it just says no.
  final bool offline;

  @override
  String toString() => message;
}

/// Calls the auth endpoints of the server.
class AuthRepository {
  AuthRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  // The same message as everywhere else, plus whether the server was reachable at
  // all — that is what the screen shows as offline.
  AuthException _error(DioException failure) =>
      AuthException(serverErrorMessage(failure), offline: failure.type == DioExceptionType.connectionError);

  /// POST /api/register, which creates the user and returns it including its id.
  Future<User> register({required String username, required String password}) async {
    Response response;
    try {
      response = await _dio.post('$apiBaseUrl/api/register', data: {
        'username': username,
        'password': password,
      });
    } on DioException catch (error) {
      throw _error(error);
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
      throw _error(error);
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
      throw _error(error);
    }
  }

  Future<void> logout() => session.clear();
}
