import 'package:dio/dio.dart';

import '../../../core/config/api_config.dart';
import '../domain/user.dart';

/// Raised when registration or login fails: the message from the server, or our
/// own explanation when the server was not reachable.
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Calls the auth endpoints of the server.
class AuthRepository {
  AuthRepository(this._dio);

  final Dio _dio;

  /// POST /api/register, which creates the user and returns it including its id.
  Future<User> register({required String username, required String email, required String password}) {
    return _post('/api/register', {'username': username, 'email': email, 'password': password});
  }

  /// POST /api/login with a username or an address and the password.
  Future<User> login({required String login, required String password}) {
    return _post('/api/login', {'login': login, 'password': password});
  }

  Future<User> _post(String path, Map<String, String> body) async {
    final Response response;
    try {
      response = await _dio.post('$apiBaseUrl$path', data: body);
    } on DioException catch (error) {
      throw AuthException(errorMessageFor(error));
    }

    return User.fromJson(response.data as Map<String, dynamic>);
  }

  String errorMessageFor(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    if (error.type == DioExceptionType.connectionError) {
      return 'Server ist nicht erreichbar unter $apiBaseUrl.';
    }
    return 'Anfrage fehlgeschlagen (${error.response?.statusCode ?? 'unbekannter Status'}).';
  }
}
