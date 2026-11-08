import 'package:dio/dio.dart';

import '../config/api_config.dart';

/// What a failed call to the server shows the user: the server's own message
/// when it answered, otherwise our own explanation. Every feature that calls the
/// API uses this, so they all say the same thing the same way.
String serverErrorMessage(DioException error) {
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
