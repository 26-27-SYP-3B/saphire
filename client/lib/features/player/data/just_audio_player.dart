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

  /// just_audio's `play()` future completes only when the song ends or is paused, not when
  /// playback starts. Awaiting it would keep every caller busy for the whole song — the pause
  /// button and every row in the queue would stay dead while a song plays.
  ///
  /// The request is not dropped: a start that fails surfaces as the player's state, and nobody is
  /// left to return that error to, so it must not become an uncaught error in the console.
  @override
  Future<void> play() async {
    _player.play().ignore();
  }

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

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Duration get position => _player.position;

  @override
  Duration get duration => _player.duration ?? Duration.zero;

  @override
  Future<void> seek(Duration at) => _player.seek(at);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() => _player.dispose();
}
