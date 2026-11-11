import 'dart:async';

import '../../../core/config/api_config.dart';
import '../../../core/storage/file_exists.dart';
import '../../../core/storage/session_store.dart';
import '../../library/domain/local_track.dart';
import 'queue.dart';

/// What a player needs from the audio plugin: open one song, play, pause, stop, and be
/// told when a song ended. This is behind an interface because the queue logic has to be
/// testable — `just_audio` has no platform plugin during a test run, so the real player
/// cannot be used there. See data/just_audio_player.dart for the implementation.
abstract interface class SongPlayer {
  Future<void> open(String url, {Map<String, String> headers});
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Emits when a song finished. A queue uses this to move to the next entry, which is
  /// the whole reason a queue is worth having.
  Stream<void> get completed;

  bool get playing;

  /// Releases the audio object behind the player. The queue is the only thing that holds a
  /// player for the life of the app, so this is where it is closed.
  Future<void> dispose();
}

/// A song that could not be opened. The message is what the page shows, so a missing
/// file says that it is missing and not that the player failed.
class PlaybackException implements Exception {
  PlaybackException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Plays a queue: the entry that is current, then the next one when a song ends. It
/// knows only a queue and something that can play a URL, so a queue filled from a
/// playlist and a queue filled from one song play exactly the same way — that is what
/// makes the queue universal.
class QueuePlayer {
  QueuePlayer({required this.queue, required this.player, required this.session}) {
    _subscriptions.add(player.completed.listen((_) => _onCompleted()));
  }

  final PlaybackQueue queue;
  final SongPlayer player;
  final SessionStore session;

  final List<StreamSubscription<void>> _subscriptions = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// What an attempt by itself reported. A song that ends on its own has no tap behind it,
  /// so an error there would be a future nobody looks at, and the page would show a new
  /// current song without saying that opening it failed. A page that shows the queue reads
  /// this when it rebuilds.
  String? failure;

  /// Emits when the player moved to a different entry. A page that shows the queue has
  /// to listen: when a song ends by itself, nothing the user did would redraw it, and
  /// the screen would keep showing the song that just finished.
  Stream<void> get changes => _changes.stream;

  /// The local songs that were started as one list, and which of them is current. A
  /// local song has no slot in the server queue, so the bar and the queue page read this
  /// instead of queue.current.
  final List<LocalTrack> _local = [];
  int _localIndex = -1;

  List<LocalTrack> get localQueue => List.unmodifiable(_local);

  LocalTrack? get localCurrent =>
      (_localIndex >= 0 && _localIndex < _local.length) ? _local[_localIndex] : null;

  String? get localTitle => localCurrent?.title;

  /// A queue entry is a reference to a library song, so the bytes come from the
  /// streaming endpoint. The endpoint sends the file in chunks, which is what a player
  /// needs: the first piece arrives before the rest of the file is read.
  String urlFor(int trackId) => '$apiBaseUrl/api/music/$trackId';

  /// Plays a file that is on the device: from its path when the pick gave one, from the
  /// bytes when it came from a browser. This is the whole local mode — no server, no
  /// queue, just the player and the file.
  Future<void> playLocal(LocalTrack track) async {
    _local
      ..clear()
      ..add(track);
    _localIndex = 0;
    queue.clear();
    await _openLocal();
  }

  /// Plays a list from the device in order, the way a playlist does. The list is copied,
  /// so later changes to the stored queue do not change what this player is playing.
  Future<void> playLocalQueue(List<LocalTrack> tracks) async {
    if (tracks.isEmpty) throw PlaybackException('Die Warteschlange ist leer, es gibt nichts zu spielen.');

    _local
      ..clear()
      ..addAll(tracks);
    _localIndex = 0;
    queue.clear();
    await _openLocal();
  }

  Future<void> _openLocal() async {
    final track = localCurrent;
    if (track == null) throw PlaybackException('Die Warteschlange ist leer, es gibt nichts zu spielen.');

    final path = track.path;
    final bytes = track.bytes;
    if (path == null && bytes == null) {
      // The file did not open, so the bar must not name it as the one that is playing.
      _localIndex = -1;
      throw PlaybackException('Die Datei wurde nicht gefunden: ${track.title}');
    }
    // A file the user deleted or moved is only noticed here, because the library keeps
    // the path and not the file.
    if (path != null && !fileExists(path)) {
      _localIndex = -1;
      throw PlaybackException('Die Datei wurde nicht gefunden: ${track.title}');
    }

    failure = null;
    try {
      await player.open(
        path != null ? Uri.file(path).toString() : Uri.dataFromBytes(bytes!, mimeType: 'audio/mpeg').toString(),
      );
    } catch (_) {
      // The file did not open, so the bar must not name it as the one that is playing.
      _localIndex = -1;
      rethrow;
    }
    _changes.add(null);
    await player.play();
  }

  /// Keeps the player's local order in step with the stored queue when a row is removed.
  /// The removed row may be the one that is audible, so that audio stops with it.
  ///
  /// Matched by identity, not by index: the player's copy may have been made before the
  /// page's list changed, and then a position would point at a different song.
  Future<void> removeLocal(LocalTrack track) async {
    var index = _local.indexOf(track);
    if (index < 0) return;

    // The same song can be queued twice: a removal must drop a copy that is not audible.
    if (index == _localIndex) {
      final other = _local.lastIndexOf(track);
      if (other != index) index = other;
    }

    if (index == _localIndex) {
      await player.stop();
      _local.removeAt(index);
      _localIndex = -1;
    } else {
      _local.removeAt(index);
      if (_localIndex > index) _localIndex -= 1;
    }
    _changes.add(null);
  }

  /// The local queue was emptied: the audio stops with it, so the page and the player
  /// say the same thing.
  Future<void> clearLocalQueue() async {
    await player.stop();
    _local.clear();
    _localIndex = -1;
    _changes.add(null);
  }

  /// Replaces the order without stopping the song that is playing. Used when a song is
  /// added to the queue while another one is open: the next song has to be the new list.
  void syncLocalQueue(List<LocalTrack> tracks) {
    final current = localCurrent;
    _local
      ..clear()
      ..addAll(tracks);
    _localIndex = current == null ? -1 : _local.indexOf(current);
  }

  Future<void> playCurrent() async {
    // A server queue replaces what the device was playing from a list.
    _local.clear();
    _localIndex = -1;

    // Nothing is current until a player starts one. A queue that was just filled plays
    // from its first song, which is what pressing play means.
    final entry = queue.current ?? queue.advance();
    if (entry == null) return;

    failure = null;

    // The token is only sent when there is one. "Bearer null" would be answered as an
    // unknown session, and the message the user sees would be about a token they never
    // sent.
    final token = session.token;
    await player.open(
      urlFor(entry.trackId),
      headers: token == null ? const {} : {'Authorization': 'Bearer $token'},
    );
    await player.play();
  }

  /// Starts the song that was opened last again. A local file has no queue entry, so the
  /// play button cannot mean playCurrent for it.
  Future<void> resume() => player.play();

  /// Moves to the next song and plays it. Returns false when the queue is finished, so
  /// the page can say so instead of waiting for a song that is not there. Pressing next
  /// at the end ends playback: there is nothing left to play.
  Future<bool> next() async {
    // A local list is its own queue. Nothing is stored for it, but it moves the same way.
    // Only a list that is at a song owns playback; an index of -1 means the local list
    // already ended and a server queue may be what plays next.
    if (_localIndex >= 0) {
      if (_localIndex < _local.length - 1) {
        _localIndex += 1;
        _changes.add(null);
        await _openLocal();
        return true;
      }
      _localIndex = -1;
      _changes.add(null);
      await player.stop();
      return false;
    }

    if (queue.advance() == null) {
      _changes.add(null);
      await player.stop();
      return false;
    }

    _changes.add(null);
    await playCurrent();
    return true;
  }

  Future<void> pause() => player.pause();

  Future<void> stop() => player.stop();

  /// Whether audio is playing right now. A page that removes a row needs this: the row it
  /// is taking out may be the one that is audible, and then the audio has to move with it.
  bool get playing => player.playing;

  Future<void> _onCompleted() async {
    // Same rule as the next button: a local list only owns playback while a song of it is
    // current. Otherwise the server queue is what moves on.
    if (_localIndex >= 0) {
      if (_localIndex < _local.length - 1) {
        _localIndex += 1;
        try {
          await _openLocal();
        } catch (error) {
          failure = 'Das Lied konnte nicht gespielt werden: $error';
        }
        _changes.add(null);
        return;
      }

      _localIndex = -1;
      _changes.add(null);
      await player.stop();
      return;
    }

    if (queue.advance() == null) {
      _changes.add(null);
      await player.stop();
      return;
    }

    try {
      await playCurrent();
    } catch (error) {
      // Nothing was tapped here, so an error would be a future nobody looks at. A song
      // that stops in the middle is not a JSON error either: the status was already sent,
      // so the only sign is that the body stopped.
      failure = 'Das Lied konnte nicht gespielt werden: $error';
    }

    _changes.add(null);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    await _changes.close();
    await player.dispose();
  }
}
