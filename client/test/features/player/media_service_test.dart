import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/features/player/data/media_service.dart';
import 'package:saphire_client/features/player/domain/queue.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

/// The phone builds its notification, lock-screen controls and Bluetooth buttons from what the
/// handler reports, so these tests read the same two streams the plugin reads. No platform is
/// needed for that: the handler only translates the queue.
void main() {
  Future<(MediaService, Wiring)> openSong(FakePlayer audio) async {
    final wiring = Wiring(loggedIn(), queueAdapter: StubAdapter(200, <Object>[]), audio: audio);
    addTearDown(wiring.dispose);

    wiring.queue.fill([QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3')]);
    await wiring.player.playCurrent();
    audio.length(const Duration(seconds: 30));

    final service = MediaService(wiring.player);
    await pumpEventQueue();
    return (service, wiring);
  }

  test('a paused song is ready, not loading', () async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final (service, _) = await openSong(audio);

    expect(service.mediaItem.value?.title, 'Technogal.mp3');
    expect(service.playbackState.value.playing, isTrue);

    await service.pause();

    expect(service.playbackState.value.playing, isFalse);
    // "buffering" would put a spinner on the phone for as long as the song stays paused.
    expect(service.playbackState.value.processingState, AudioProcessingState.ready);
    expect(service.playbackState.value.controls, contains(MediaControl.play));

    await service.play();
    expect(service.playbackState.value.playing, isTrue);
    expect(service.playbackState.value.controls, contains(MediaControl.pause));
  });

  test('stopping closes the notification, and a song that plays again gets it back', () async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final (service, wiring) = await openSong(audio);

    await service.stop();

    expect(service.playbackState.value.processingState, AudioProcessingState.idle);
    expect(service.playbackState.value.playing, isFalse);
    expect(service.playbackState.value.controls, isEmpty);

    audio.at(const Duration(seconds: 3));
    await pumpEventQueue();
    expect(service.playbackState.value.processingState, AudioProcessingState.idle);

    // Play can come from the app and not from the notification, so a song that runs again must not
    // stay without a notification.
    await wiring.player.resume();
    audio.at(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(service.playbackState.value.processingState, AudioProcessingState.ready);
    expect(service.playbackState.value.playing, isTrue);
  });

  // A position tick moves the progress bar and nothing else. A new item five times a second would
  // rebuild the notification for a song that did not change.
  test('a position tick moves the progress and does not send a new song', () async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final (service, _) = await openSong(audio);

    final item = service.mediaItem.value;
    audio.at(const Duration(seconds: 4));
    await pumpEventQueue();

    expect(identical(service.mediaItem.value, item), isTrue);
    expect(service.playbackState.value.updatePosition, const Duration(seconds: 4));
  });

  // A row opened from the queue page has no next() or previous() behind it, so the notification has
  // to be told by the player itself.
  test('a row opened from a page renames the notification and brings its length', () async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = Wiring(loggedIn(), queueAdapter: StubAdapter(200, <Object>[]), audio: audio);
    addTearDown(wiring.dispose);
    wiring.queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
      QueueEntry(position: 2, trackId: 4, title: 'lied.wav'),
    ]);
    await wiring.player.playCurrent();
    audio.length(const Duration(seconds: 30));

    final service = MediaService(wiring.player);
    await pumpEventQueue();
    expect(service.mediaItem.value?.title, 'Technogal.mp3');

    await wiring.player.playAt(wiring.queue.entries[1]);
    // The length arrives with the file, a moment after the open.
    audio.length(const Duration(seconds: 12));
    audio.at(Duration.zero);
    await pumpEventQueue();

    expect(service.mediaItem.value?.title, 'lied.wav');
    expect(service.mediaItem.value?.duration, const Duration(seconds: 12));
  });

  // The last song is over: nothing is current any more, so the notification has to go instead of
  // showing the finished song as if it still played.
  test('the end of the queue turns the notification off', () async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final (service, wiring) = await openSong(audio);

    expect(await wiring.player.next(), isFalse);
    await pumpEventQueue();

    expect(service.playbackState.value.processingState, AudioProcessingState.idle);
    expect(service.playbackState.value.playing, isFalse);
    expect(service.mediaItem.value, isNull);
  });
}
