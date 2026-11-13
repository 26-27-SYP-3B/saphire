import 'dart:async';

import 'package:saphire_client/features/player/domain/audio_engine.dart';

/// The audio plugin has no platform inside a test, so the player is given this engine:
/// it records what it was asked for and answers with what the test hands it.
class FakeEngine implements AudioEngine {
  FakeEngine({this.openError});

  final String? openError;

  final List<String> opened = [];
  final List<Map<String, String>> sentHeaders = [];
  final List<String> calls = [];

  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration?>.broadcast();
  final _error = StreamController<String>.broadcast();

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Future<void> open(String url, Map<String, String> headers) async {
    opened.add(url);
    sentHeaders.add(headers);
    calls.add('open');
    if (openError != null) throw AudioException(openError!);
  }

  @override
  Future<void> play() async {
    calls.add('play');
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration to) async {
    calls.add('seek');
    _position.add(to);
  }

  /// A test reports a length as if the stream had read its header.
  void report(Duration position, Duration length) {
    _duration.add(length);
    _position.add(position);
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _error.close();
  }
}
