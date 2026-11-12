import 'dart:async';

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
    _subscriptions
      ..add(player.changes.listen((_) => _report()))
      ..add(player.positionStream.listen((position) => _report(position)));

    _report();
  }

  final QueuePlayer player;
  final List<StreamSubscription<void>> _subscriptions = [];

  @override
  Future<void> play() => player.resume();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    await player.stop();
    _report();
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

  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }

  void _report([Duration? at]) {
    // The bar and the notification name the same song: what the player is at. A file on this
    // device is not in the queue, so the local list is what the plugin gets here.
    final entry = player.queue.current;
    final local = player.localCurrent;
    final title = local?.title ?? entry?.title;
    if (title == null) return;

    // A song on this device has no id the plugin could use, and no artist: neither a queue answer
    // nor a picked file names one, so the notification shows the title alone.
    mediaItem.add(MediaItem(
      id: local != null ? local.path ?? title : '${entry!.trackId}',
      title: title,
      duration: player.duration,
    ));

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (player.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        playing: player.playing,
        processingState: player.playing ? AudioProcessingState.ready : AudioProcessingState.buffering,
        updatePosition: at ?? player.position,
      ),
    );
  }
}
