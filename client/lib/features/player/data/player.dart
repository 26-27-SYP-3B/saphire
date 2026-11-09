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

// One player for the app: a new AudioPlayer per song would keep one alive for
// every song that was ever started.
final _audio = AudioPlayer();

Future<void> playWithJustAudio(String url, Map<String, String> headers) async {
  await _audio.setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers));
  await _audio.play();
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

  /// Songs waiting behind the current one; shortcut: nothing plays them, the queue itself is another part of the app.
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

    String? failed;
    try {
      await _play('$apiBaseUrl/api/music/${track.id}', {'Authorization': 'Bearer ${session.token}'});
    } on DioException catch (failure) {
      failed = serverErrorMessage(failure);
    } catch (failure) {
      // What the player itself reports is text no user can read, so the bar only
      // says the song could not be started.
      failed = 'Der Song konnte nicht abgespielt werden.';
    }

    // Only the song that is still current may show its error: a newer play has taken
    // its place while this one was failing.
    if (failed != null && current == track) error = failed;
    notifyListeners();
  }
}
