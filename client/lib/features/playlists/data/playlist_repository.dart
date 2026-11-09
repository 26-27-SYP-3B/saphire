import 'package:dio/dio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../domain/playlist.dart';

/// Raised when a playlist call fails. The message is the server's own, so what the page
/// shows is what api-docs.md describes.
class PlaylistException implements Exception {
  PlaylistException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Calls the playlist endpoints. Every one of them reads only the caller's own
/// playlists, so a playlist of another user comes back as 404 with "playlist is not in
/// your playlists" — the same message the page shows.
class PlaylistRepository {
  PlaylistRepository(this._dio, this.session);

  final Dio _dio;
  final SessionStore session;

  // The header is only built when there is a token. "Bearer null" would be answered as an
  // unknown session, and the user would read a message about a token they never sent.
  Map<String, String> get _headers {
    final token = session.token;
    return token == null ? const {} : {'Authorization': 'Bearer $token'};
  }

  Future<Playlist> create(String name) async {
    try {
      final response = await _dio.post(
        '$apiBaseUrl/api/playlists',
        data: {'name': name},
        options: Options(headers: _headers),
      );
      return Playlist.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw PlaylistException(serverErrorMessage(error));
    }
  }

  /// The caller's playlists. An empty library answers [], never null.
  Future<List<Playlist>> list() async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/playlists',
        options: Options(headers: _headers),
      );
      return (response.data as List)
          .map((entry) => Playlist.fromJson(entry as Map<String, dynamic>))
          .toList();
    } on DioException catch (error) {
      throw PlaylistException(serverErrorMessage(error));
    }
  }

  Future<PlaylistWithSongs> get(int id) async {
    try {
      final response = await _dio.get(
        '$apiBaseUrl/api/playlists/$id',
        options: Options(headers: _headers),
      );
      return PlaylistWithSongs.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw PlaylistException(serverErrorMessage(error));
    }
  }

  /// Adds a song at the end and returns the position it got. The track id must be a
  /// library id.
  Future<PlaylistSong> addSong(int playlistId, int trackId) async {
    try {
      final response = await _dio.post(
        '$apiBaseUrl/api/playlists/$playlistId/songs',
        data: {'track_id': trackId},
        options: Options(headers: _headers),
      );
      return PlaylistSong.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (error) {
      throw PlaylistException(serverErrorMessage(error));
    }
  }

  /// Removes one position. The songs after it are renumbered, so the next position a
  /// client shows is the one the server answered with.
  Future<void> removeSong(int playlistId, int position) async {
    try {
      await _dio.delete(
        '$apiBaseUrl/api/playlists/$playlistId/songs/$position',
        options: Options(headers: _headers),
      );
    } on DioException catch (error) {
      throw PlaylistException(serverErrorMessage(error));
    }
  }

  /// Deletes the playlist. The songs stay in the shared library.
  Future<void> delete(int playlistId) async {
    try {
      await _dio.delete(
        '$apiBaseUrl/api/playlists/$playlistId',
        options: Options(headers: _headers),
      );
    } on DioException catch (error) {
      throw PlaylistException(serverErrorMessage(error));
    }
  }
}
