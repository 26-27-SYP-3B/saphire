import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../domain/player.dart';

/// The player the app really uses. just_audio reads the streaming endpoint URL, so the
/// file arrives piece by piece and a song starts before the rest of it is read.
class JustAudioPlayer implements SongPlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<void> open(String url, {Map<String, String> headers = const {}}) async {
    await _player.setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  /// just_audio reports the end of a song through its state stream. That is what a queue
  /// uses to move to the next entry, so this is the part the queue depends on.
  @override
  Stream<void> get completed => _player.playerStateStream
      .where((state) => state.processingState == ProcessingState.completed);

  @override
  bool get playing => _player.playing;

  Future<void> dispose() => _player.dispose();
}
