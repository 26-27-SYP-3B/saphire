import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:just_audio/just_audio.dart';

import '../../../core/api/server_error.dart';
import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../../upload/domain/track.dart';

/// Starting one song. A widget test hands in its own function, because the audio
/// plugin has no platform there — the same reason the file picker is injected.
typedef PlayAudio = Future<void> Function(String url, Map<String, String> headers);

Future<void> playWithJustAudio(String url, Map<String, String> headers) async {
  final audio = AudioPlayer();
  await audio.setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers));
  await audio.play();
}

/// The song that is playing and the ones waiting behind it. Every screen shows the
/// same thing, so it says when it changes.
class Player extends ChangeNotifier {
  Player(this.session, [this._play = playWithJustAudio]);

  final SessionStore session;
  final PlayAudio _play;

  Track? current;

  /// What went wrong with the last song, so the bar can say it instead of
  /// quietly showing nothing.
  String? error;

  final List<Track> queue = [];

  /// A song is queued once, the same rule as in a playlist.
  void addToQueue(Track track) {
    if (!queue.any((item) => item.id == track.id)) {
      queue.add(track);
      notifyListeners();
    }
  }

  /// Streams one song with `GET /api/music/{id}` (api-docs.md): the server sends
  /// the file in chunks, so the player starts before the whole song is read.
  Future<void> play(Track track) async {
    current = track;
    error = null;
    notifyListeners();

    try {
      await _play('$apiBaseUrl/api/music/${track.id}', {'Authorization': 'Bearer ${session.token}'});
    } on DioException catch (failure) {
      error = serverErrorMessage(failure);
    } catch (failure) {
      error = '$failure';
    }
    notifyListeners();
  }
}
