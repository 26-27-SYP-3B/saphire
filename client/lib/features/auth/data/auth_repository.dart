import 'package:dio/dio.dart';

import '../../../core/config/api_config.dart';
import '../domain/user.dart';

/// Raised when registration fails: the message from the server, or our own
/// explanation when the server was not reachable.
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Calls the registration endpoints of the server.
class AuthRepository {
  AuthRepository(this._dio);

  final Dio _dio;

  /// POST /api/register, which returns the stored user including its id.
  Future<User> register({required String name, required String email}) async {
    final Response response;
    try {
      response = await _dio.post(
        '$apiBaseUrl/api/register',
        data: {'name': name, 'email': email},
      );
    } on DioException catch (error) {
      throw AuthException(errorMessageFor(error));
    }

    return User.fromJson(response.data as Map<String, dynamic>);
  }

  String errorMessageFor(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (error.type == DioExceptionType.connectionError) {
      return 'Server is not reachable at $apiBaseUrl.';
    }
    return 'Registration failed (${error.response?.statusCode ?? 'unknown status'}).';
  }
}
