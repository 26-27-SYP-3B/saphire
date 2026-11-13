import 'dart:async';

import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../../library/domain/library_entry.dart';
import 'audio_engine.dart';

/// What the player bar shows: which song, whether it is playing, how far it is, and what
/// went wrong when something did.
class Playback {
  const Playback({
    this.song,
    this.playing = false,
    this.position = Duration.zero,
    this.duration,
    this.error,
  });

  final LibraryEntry? song;
  final bool playing;
  final Duration position;
  final Duration? duration;
  final String? error;
}

/// Plays one song at a time out of the stream.
///
/// This is the only place in the client that knows how a song is reached: the id, the
/// address built from it, and the session token. The library list carries no file path,
/// so a title is not enough to hear a song.
class Player {
  Player(this._engine, this.session) {
    _subscriptions.addAll([
      _engine.playingStream.listen((playing) {
        _playing = playing;
        _publish();
      }),
      _engine.positionStream.listen((position) {
        _position = position;
        _publish();
      }),
      _engine.durationStream.listen((duration) {
        _duration = duration;
        _publish();
      }),
      _engine.errorStream.listen((message) {
        _error = message;
        _publish();
      }),
    ]);
  }

  final AudioEngine _engine;
  final SessionStore session;
  final List<StreamSubscription> _subscriptions = [];
  final StreamController<Playback> _changes = StreamController.broadcast();

  LibraryEntry? _song;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  String? _error;

  /// The state as it is right now, so a widget that subscribes after a song already
  /// started still shows that song instead of an empty bar.
  Playback get current => Playback(
    song: _song,
    playing: _playing,
    position: _position,
    duration: _duration,
    error: _error,
  );

  Stream<Playback> get playback => _changes.stream;

  /// The address of one song. The id is the only way to a file: the name inside the
  /// library folder is not in the list answer (api-docs.md).
  String streamUrl(int id) => '$apiBaseUrl/api/music/$id';

  Future<void> playSong(LibraryEntry entry) async {
    _song = entry;
    _playing = false;
    _position = Duration.zero;
    _duration = null;
    _error = null;
    _publish();

    try {
      await _engine.open(streamUrl(entry.id), {'Authorization': 'Bearer ${session.token}'});
      await _engine.play();
    } on AudioException catch (error) {
      _error = error.message;
      _publish();
    }
  }

  Future<void> toggle() async {
    if (_song == null) return;
    if (_playing) {
      await _engine.pause();
    } else {
      await _engine.play();
    }
  }

  /// A seek is a new request for a byte range, so the player does not wait for the rest
  /// of the file.
  Future<void> seekTo(Duration to) async {
    if (_song == null) return;
    await _engine.seek(to);
  }

  void _publish() {
    if (_changes.isClosed) return;
    _changes.add(current);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _changes.close();
    await _engine.dispose();
  }
}
