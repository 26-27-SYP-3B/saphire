import 'dart:async';

import 'package:saphire_client/features/player/domain/player.dart';

/// A player that needs no platform: it records what it was asked to do and can be told
/// that a song ended. `just_audio` has no plugin during a test run, so the queue logic is
/// tested against this instead of against the real player.
class FakePlayer implements SongPlayer {
  final StreamController<void> _completed = StreamController<void>.broadcast();
  final StreamController<Duration> _positions = StreamController<Duration>.broadcast();
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// The URLs opened, in order. The URL is what the streaming endpoint serves, so this is
  /// how a test sees which song the queue chose.
  final List<String> opened = [];
  final List<String> played = [];
  final List<String> stopped = [];

  bool _playing = false;

  @override
  Future<void> open(String url, {Map<String, String> headers = const {}}) async {
    if (openError != null) throw Exception(openError);
    opened.add(url);
    lastHeaders = headers;
  }

  Map<String, String> lastHeaders = const {};

  /// When set, `open` fails with this instead of recording the url — for a test that wants
  /// to see what happens when the next song cannot be opened.
  String? openError;

  @override
  Future<void> play() async {
    played.add(opened.last);
    _playing = true;
  }

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> stop() async {
    stopped.add(opened.isEmpty ? '' : opened.last);
    _playing = false;
  }

  @override
  Stream<void> get completed => _completed.stream;

  @override
  bool get playing => _playing;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  /// What the player was asked to jump to, and what it was asked to set as the volume. A test
  /// that checks a progress bar or a volume slider reads these.
  final List<Duration> sought = [];
  final List<double> volumes = [];

  /// Where a test says the song is, and how long it is, so a seek can be checked against a real
  /// length instead than against nothing.
  void at(Duration position) {
    _position = position;
    _positions.add(position);
  }

  void length(Duration total) => _duration = total;

  @override
  Future<void> seek(Duration at) async {
    sought.add(at);
    _position = at;
    _positions.add(at);
  }

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  /// Says "this song ended", which is what moves a queue to the next entry.
  void complete() => _completed.add(null);

  @override
  Future<void> dispose() async {
    await _completed.close();
    await _positions.close();
  }
}
