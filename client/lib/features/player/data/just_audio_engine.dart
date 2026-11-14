import 'package:just_audio/just_audio.dart';

import '../domain/audio_engine.dart';

/// The engine of a real run.
///
/// just_audio sends the headers through a local proxy it starts on the device. On web a
/// browser cannot add a header to an audio element at all, so a browser player would have
/// to authenticate through the url — which this API does not offer. Playback from a
/// browser tab therefore does not work with the endpoints as they are documented; on a
/// device it does.
class JustAudioEngine implements AudioEngine {
  JustAudioEngine(this._player);

  final AudioPlayer _player;

  @override
  Stream<bool> get playingStream => _player.playingStream;

  @override
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Stream<Duration?> get durationStream => _player.durationStream;

  @override
  Stream<String> get errorStream =>
      _player.errorStream.map((error) => error.message ?? 'der Stream konnte nicht gelesen werden');

  @override
  Future<void> open(String url, Map<String, String> headers) async {
    try {
      await _player.setAudioSource(AudioSource.uri(Uri.parse(url), headers: headers));
    } on PlayerException catch (error) {
      throw AudioException(error.message ?? 'der Stream konnte nicht geöffnet werden');
    }
  }

  @override
  Future<void> play() => _run(() => _player.play());

  @override
  Future<void> pause() => _run(() => _player.pause());

  @override
  Future<void> seek(Duration to) => _run(() => _player.seek(to));

  /// A failure here is named like one from open(), because the player bar is built to show
  /// one kind of error and would otherwise miss these.
  Future<void> _run(Future<void> Function() call) async {
    try {
      await call();
    } on PlayerException catch (error) {
      throw AudioException(error.message ?? 'der Stream konnte nicht gelesen werden');
    }
  }

  @override
  Future<void> dispose() => _player.dispose();
}
