import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/track.dart';

/// Raised when an upload fails.
class UploadException implements Exception {
  UploadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Calls the upload endpoint. Only a logged-in user may upload, so the stored
/// session token goes as a Bearer header; the file itself is a form field named
/// "file", which is the name the server checks for. The size limit and the audio
/// check are the server's, so the file is sent as it is.
class UploadRepository {
  UploadRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  Future<Track> upload({
    required String filename,
    required Uint8List bytes,
    ProgressCallback? onProgress,
  }) async {
    try {
      final response = await _dio.post(
        '$apiBaseUrl/api/music/upload',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: filename),
        }),
        options: Options(headers: {'Authorization': 'Bearer ${session.token}'}),
        onSendProgress: onProgress,
      );
      return Track.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw UploadException(serverErrorMessage(error));
    } on TypeError {
      // A response that is not the documented object throws here; the user is not shown the type error.
      throw UploadException(unreadableAnswer);
    }
  }
}
