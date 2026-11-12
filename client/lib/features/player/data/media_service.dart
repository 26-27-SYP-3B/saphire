import 'package:audio_service/audio_service.dart';

import '../domain/player.dart';

/// What a phone shows when the app is not in the foreground: the media notification, the
/// lock-screen controls and the buttons on a Bluetooth device. The plugin builds all of these from
/// what a handler reports, so this file only translates the queue into those reports — the queue
/// itself stays in domain/player.dart, and a tap in the notification calls the same methods the bar
/// calls, so the two cannot disagree about what is playing.
///
/// shortcut: the app and the notification share this one handler, so audio keeps playing while the
/// app is in the background but not after the process is killed. If playback has to survive a
/// restart, the handler has to be built inside the plugin's background service
/// (`initializeAudioService`) and own the queue there.
class MediaService extends BaseAudioHandler {
  MediaService(this.player) {
    // The handler lives as long as the app, so nothing here is cancelled: the player is the only
    // owner of these streams and it ends with the process.
    player.changes.listen((_) => _report());
    player.positionStream.listen(_reportPosition);

    _report();
  }

  final QueuePlayer player;

  /// A closed notification has to stay closed: the position stream keeps ticking after a stop, and
  /// without this the next tick would build the notification again.
  bool _stopped = false;

  @override
  Future<void> play() async {
    _stopped = false;
    await player.resume();
    _reportState();
  }

  @override
  Future<void> pause() async {
    await player.pause();
    // Reported here, because a pause from the notification has no tap in the app behind it and the
    // icon has to change now, not on the next position tick.
    _reportState();
  }

  @override
  Future<void> stop() async {
    await player.stop();
    _stopped = true;

    // Nothing is loaded any more, which is what makes Android drop the notification.
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  @override
  Future<void> skipToNext() async {
    await player.next();
    _report();
  }

  @override
  Future<void> skipToPrevious() async {
    await player.previous();
    _report();
  }

  /// The progress bar in the notification moves the song to the moment it is dragged to.
  @override
  Future<void> seek(Duration position) => player.seek(position);

  /// The player moved, so the notification may name a different song. The item is sent only when it
  /// really changed: a new item on every position tick rebuilds the notification five times a
  /// second for nothing.
  void _report() {
    // The bar and the notification name the same song: what the player is at. A file on this
    // device is not in the queue, so the local list is what the plugin gets here.
    final entry = player.queue.current;
    final local = player.localCurrent;
    final title = local?.title ?? entry?.title;
    if (title == null) {
      // Nothing is playing any more — the queue ended or was emptied — so the notification goes with
      // it instead of naming a song that is over.
      mediaItem.add(null);
      playbackState.add(playbackState.value.copyWith(
        controls: const [],
        playing: false,
        processingState: AudioProcessingState.idle,
      ));
      return;
    }

    // A song on this device has no id the plugin could use, and no artist: neither a queue answer
    // nor a picked file names one, so the notification shows the title alone.
    final shown = mediaItem.value;
    if (shown == null || shown.title != title || shown.duration != player.duration) {
      mediaItem.add(MediaItem(
        id: local != null ? local.path ?? title : '${entry!.trackId}',
        title: title,
        duration: player.duration,
      ));
    }

    _reportState();
  }

  /// A tick mostly moves the progress, but the length of a song is only known once the player has
  /// read the file, so the first tick after that is when the notification can show the right total.
  void _reportPosition(Duration at) {
    final item = mediaItem.value;
    if (item != null && item.duration != player.duration) return _report();

    _reportState(at);
  }

  void _reportState([Duration? at]) {
    // A dismissed notification stays away until something plays again — and play can come from the
    // app, not only from the notification, so the state it is in decides, not the flag alone.
    if (_stopped && !player.playing) return;
    _stopped = false;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        playing: player.playing,
        // A paused song is ready, not loading: "buffering" would show a spinner on the phone for
        // as long as the song stays paused.
        processingState: AudioProcessingState.ready,
        updatePosition: at ?? player.position,
      ),
    );
  }
}
