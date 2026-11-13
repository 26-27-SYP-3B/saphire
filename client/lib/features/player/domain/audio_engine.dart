import 'dart:async';

/// Raised when a stream cannot be opened or played, with the same shape as the other
/// feature errors: the message is what the page shows.
class AudioException implements Exception {
  AudioException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the app needs from an audio engine: open a stream, control it, and be told what
/// changed.
///
/// This stays an interface on purpose. The audio plugin has no platform inside a test, so
/// a test gives the player a fake engine that records what it was asked for; in a real
/// run the engine is just_audio (data/just_audio_engine.dart). Nothing else about the
/// player changes between the two.
abstract class AudioEngine {
  Stream<bool> get playingStream;
  Stream<Duration> get positionStream;
  Stream<Duration?> get durationStream;
  Stream<String> get errorStream;

  Future<void> open(String url, Map<String, String> headers);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration to);

  Future<void> dispose();
}
