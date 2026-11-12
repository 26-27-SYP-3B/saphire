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
  /// Starts playback and returns once it has started — not when the song ends. just_audio's own
  /// play() future completes only at the end, and a caller that awaited it would keep its buttons
  /// off for the whole song.
  Future<void> play();
  Future<void> pause();
  Future<void> stop();

  /// Emits when a song finished. A queue uses this to move to the next entry, which is
  /// the whole reason a queue is worth having.
  Stream<void> get completed;

  bool get playing;

  /// Where the song is and how long it is. A page that shows a progress bar needs both, and the
  /// media notification on a phone shows the same thing.
  Stream<Duration> get positionStream;
  Duration get position;
  Duration get duration;

  /// Jumps to a moment inside the song, and sets how loud it plays. Both are what the
  /// full-screen player on a phone has buttons for.
  Future<void> seek(Duration at);
  Future<void> setVolume(double volume);

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
  /// local song has no slot in the server queue, so the bar and the queue sheet read this
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
    _leave(null);
    _local
      ..clear()
      ..add(track);
    _localIndex = 0;
    queue.clear();
    await _startLocal();
  }

  /// Plays a list from the device in order, the way a playlist does. The list is copied,
  /// so later changes to the stored queue do not change what this player is playing.
  Future<void> playLocalQueue(List<LocalTrack> tracks) async {
    if (tracks.isEmpty) throw PlaybackException('Die Warteschlange ist leer, es gibt nichts zu spielen.');

    _leave(null);
    _local
      ..clear()
      ..addAll(tracks);
    _localIndex = 0;
    queue.clear();
    await _startLocal();
  }

  /// Opens the first song of a list that was just set. A song that cannot be opened is
  /// reported and must not become the one the bar names.
  Future<void> _startLocal() async {
    try {
      await _openLocal();
    } catch (_) {
      _localIndex = -1;
      rethrow;
    }
  }

  Future<void> _openLocal() async {
    final track = localCurrent;
    if (track == null) throw PlaybackException('Die Warteschlange ist leer, es gibt nichts zu spielen.');

    final path = track.path;
    final bytes = track.bytes;
    if (path == null && bytes == null) {
      throw PlaybackException('Die Datei wurde nicht gefunden: ${track.title}');
    }
    // A file the user deleted or moved is only noticed here, because the library keeps
    // the path and not the file.
    if (path != null && !fileExists(path)) {
      throw PlaybackException('Die Datei wurde nicht gefunden: ${track.title}');
    }

    failure = null;
    await player.open(
      path != null ? Uri.file(path).toString() : Uri.dataFromBytes(bytes!, mimeType: 'audio/mpeg').toString(),
    );
    _changes.add(null);
    await player.play();
  }

  /// Moves on to the next song of the local list that can actually be opened. A file that
  /// cannot be read is skipped instead of ending playback, and the page is still told why.
  /// Returns false when no song is left; the audio stops then, so it and the bar agree.
  Future<bool> _advanceLocal() async {
    String? skipped;
    while (_localIndex < _local.length - 1) {
      _localIndex += 1;
      try {
        await _openLocal();
        // Reported after the open, because opening a song clears the old message.
        if (skipped != null) failure = skipped;
        _changes.add(null);
        return true;
      } catch (error) {
        skipped ??= error is PlaybackException ? error.message : '$error';
      }
    }

    _localIndex = -1;
    if (skipped != null) failure = skipped;
    _changes.add(null);
    await player.stop();
    return false;
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

  /// Replaces the order without interrupting a song that is still in it. Used when a song
  /// is added to the queue while another one is open: the next song has to be the new list.
  /// A song that is no longer in the list stops with it, paused or not — otherwise the bar
  /// would name a song the queue no longer shows.
  Future<void> syncLocalQueue(List<LocalTrack> tracks) async {
    final current = localCurrent;
    _local
      ..clear()
      ..addAll(tracks);
    _localIndex = current == null ? -1 : _local.indexOf(current);

    if (current != null && _localIndex < 0) {
      await player.stop();
      _changes.add(null);
    }
  }

  /// Plays the row a page clicked and goes on from it, which is what a row in a queue means:
  /// not hearing one song once, but continuing after it. A row that is a file on this device
  /// opens the file, a row the server has opens the streaming endpoint. Returns false when the
  /// row is in neither list this player owns, because then nothing was played and the page must
  /// not say it was.
  Future<bool> playAt(QueueEntry row) async {
    final track = row.local;
    if (track != null) {
      final at = _local.indexOf(track);
      if (at < 0) return false;

      _leave(row);
      _localIndex = at;

      // The mirror and the list the player plays name the same row, so the page points at the
      // song that is audible.
      queue.index = row.position - 1;
      await _openLocal();
      return true;
    }

    if (row.position < 1 || row.position > queue.length) return false;

    _leave(row);
    queue.index = row.position - 1;
    await playCurrent();
    return true;
  }

  /// What the player leaves behind when it moves to another song. Only a song that was really
  /// opened belongs to "Zuletzt gespielt", and the song the player stays on was not played
  /// before, so the row it moves to is not recorded twice.
  void _leave(QueueEntry? next) {
    final local = localCurrent;
    final left = queue.current ?? (local == null ? null : QueueEntry.fromLocal(_localIndex + 1, local));
    if (left == null) return;
    if (next != null && identical(next, left)) return;

    queue.recordPlayed(left);
  }

  Future<void> playCurrent() async {
    // A server queue replaces what the device was playing from a list.
    _local.clear();
    _localIndex = -1;

    // Nothing is current until a player starts one. A queue that was just filled plays
    // from its first song, which is what pressing play means.
    final entry = queue.current ?? queue.advance();
    if (entry == null) {
      _changes.add(null);
      return;
    }

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

    // Reported here, because a row opened from a page has no next() or previous() behind it: without
    // this the bar, the queue and the notification would keep the song that was there before.
    _changes.add(null);
  }

  /// Starts the song that was opened last again. A local file has no queue entry, so the
  /// play button cannot mean playCurrent for it.
  Future<void> resume() => player.play();

  /// Moves to the next song and plays it. Returns false when the queue is finished, so
  /// the page can say so instead of waiting for a song that is not there. Pressing next
  /// at the end ends playback: there is nothing left to play.
  Future<bool> next() async {
    _leave(null);

    // A local list is its own queue. Nothing is stored for it, but it moves the same way.
    // Only a list that is at a song owns playback; an index of -1 means the local list
    // already ended and a server queue may be what plays next.
    if (_localIndex >= 0) return _advanceLocal();

    if (queue.advance() == null) {
      _changes.add(null);
      await player.stop();
      return false;
    }

    // playCurrent reports the song it opened, so nothing is reported here.
    await playCurrent();
    return true;
  }

  /// Jumps inside the song that is open. Clamped to the song, because a progress bar can be
  /// dragged to its end and a player asked past the end throws.
  Future<void> seek(Duration at) async {
    var to = at < Duration.zero ? Duration.zero : at;
    final total = player.duration;
    if (total > Duration.zero && to > total) to = total;
    await player.seek(to);
  }

  /// Jumps by a number of seconds from where the song is now. This is what the ten-second
  /// buttons on a phone do, and it does not move to another song.
  Future<void> skip(Duration by) => seek(player.position + by);

  /// How loud the song plays, 0 to 1. A page that shows a slider keeps the value it set; the
  /// player is the thing that actually turns the volume down.
  Future<void> setVolume(double volume) => player.setVolume(volume.clamp(0.0, 1.0));

  Stream<Duration> get positionStream => player.positionStream;
  Duration get position => player.position;
  Duration get duration => player.duration;

  /// Goes back to the song before the current one. At the first song there is nothing before it,
  /// so this says false and the page does not claim a jump it did not do.
  Future<bool> previous() async {
    // The check comes first: a press that does nothing must not write the song to the history a
    // second time.
    if ((_localIndex >= 0 ? _localIndex : queue.index) <= 0) return false;

    // The song being left is taken before the list moves, and recorded only when the move worked:
    // a song that could not be opened leaves the same song playing, and must not be written twice.
    final left = _localIndex >= 0
        ? QueueEntry.fromLocal(_localIndex + 1, _local[_localIndex])
        : queue.current;

    if (_localIndex >= 0) {
      final from = _localIndex;
      _localIndex -= 1;
      try {
        await _openLocal();
      } catch (error) {
        // The song that could not be opened is not the one being played, so the list stays at the
        // song it was at.
        _localIndex = from;
        failure = error is PlaybackException ? error.message : '$error';
        _changes.add(null);
        return false;
      }

      if (left != null) queue.recordPlayed(left);
      _changes.add(null);
      return true;
    }

    final from = queue.index;
    queue.back();
    try {
      await playCurrent();
    } catch (error) {
      // The same repair as for a local list: the slot goes back to the song that is still playing.
      queue.index = from;
      failure = error is PlaybackException ? error.message : '$error';
      _changes.add(null);
      return false;
    }

    if (left != null) queue.recordPlayed(left);
    _changes.add(null);
    return true;
  }

  Future<void> pause() => player.pause();

  Future<void> stop() => player.stop();

  /// Whether audio is playing right now. A page that removes a row needs this: the row it
  /// is taking out may be the one that is audible, and then the audio has to move with it.
  bool get playing => player.playing;

  /// What the bar and the full player write under the title. One place, because both show it and
  /// the two must not say different things about the same song.
  String get statusNote {
    if (failure != null) return failure!;

    final local = localCurrent;
    if (local != null) return 'Lokal · dieses Gerät';

    final entry = queue.current;
    return entry == null ? 'Suche ein Lied und öffne es, oder fülle die Warteschlange.' : 'Warteschlange · Slot ${entry.position}';
  }

  Future<void> _onCompleted() async {
    // The song that just ended is what was played, so it belongs to the history before the
    // player moves on.
    _leave(null);

    // Same rule as the next button: a local list only owns playback while a song of it is
    // current. Otherwise the server queue is what moves on. A file that cannot be read is
    // skipped by _advanceLocal, so one broken file does not end the list.
    if (_localIndex >= 0) {
      await _advanceLocal();
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
      // playCurrent reports a song it opened; a song it could not open has to be reported here.
      _changes.add(null);
    }
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
