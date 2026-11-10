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

  /// The local song that is playing, if the last thing started was a file from the
  /// device. A local song has no slot in the server queue, so the bar shows this
  /// instead of queue.current.
  String? localTitle;

  /// A queue entry is a reference to a library song, so the bytes come from the
  /// streaming endpoint. The endpoint sends the file in chunks, which is what a player
  /// needs: the first piece arrives before the rest of the file is read.
  String urlFor(int trackId) => '$apiBaseUrl/api/music/$trackId';

  /// Plays a file that is on the device: from its path when the pick gave one, from the
  /// bytes when it came from a browser. This is the whole local mode — no server, no
  /// queue, just the player and the file.
  Future<void> playLocal(LocalTrack track) async {
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
    // What plays now is the file, not a slot of a list the server still has.
    queue.clear();
    await player.open(
      path != null ? Uri.file(path).toString() : Uri.dataFromBytes(bytes!, mimeType: 'audio/mpeg').toString(),
    );
    localTitle = track.title;
    _changes.add(null);
    await player.play();
  }

  Future<void> playCurrent() async {
    // Nothing is current until a player starts one. A queue that was just filled plays
    // from its first song, which is what pressing play means.
    final entry = queue.current ?? queue.advance();
    if (entry == null) return;

    failure = null;
    localTitle = null;

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
    localTitle = null;
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
    localTitle = null;
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
