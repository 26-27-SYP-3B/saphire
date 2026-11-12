import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/library/domain/local_track.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';

import '../../support/fake_player.dart';
import '../../support/wiring.dart';

void main() {
  test('plays the current entry through the streaming endpoint', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
      QueueEntry(position: 2, trackId: 4, title: 'lied.wav'),
    ]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    await player.playCurrent();

    // A queue entry is a reference, so the bytes come from GET /api/music/{id}.
    expect(fake.opened, ['$apiBaseUrl/api/music/8']);
    expect(fake.lastHeaders['Authorization'], 'Bearer ${'a' * 64}');
  });

  // This is the reason a queue is worth having: a song that ends moves to the next one.
  test('when a song ends the queue plays the next entry', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    await player.playCurrent();

    // What the page listens to: without this it would keep showing the song that finished.
    final changes = <String>[];
    player.changes.listen((_) => changes.add(queue.current?.title ?? ''));

    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(queue.current?.trackId, 4);
    expect(fake.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/4']);
    expect(changes, ['b']);
  });

  // Nothing was tapped here, so an error from an auto-advance is a future nobody looks at.
  // Without this the page would show a new current song and never say that opening it
  // failed — which is the case api-docs.md describes for a stream that stops early.
  test('an auto-advance that cannot open the next song reports why', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    await player.playCurrent();

    fake.openError = 'die Verbindung wurde beendet';
    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(player.failure, contains('konnte nicht gespielt werden'));
    // The queue did move; the failure is about opening, not about the order.
    expect(queue.current?.trackId, 4);

    // The next attempt that works clears it, so the page does not keep an old error.
    fake.openError = null;
    await player.playCurrent();
    expect(player.failure, isNull);
  });

  test('at the end of the queue the player stops instead of waiting', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([QueueEntry(position: 1, trackId: 8, title: 'a')]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    await player.playCurrent();
    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(fake.opened.length, 1);
    expect(fake.stopped, ['$apiBaseUrl/api/music/8']);
    expect(queue.current, isNull);
  });

  // "Bearer null" would be answered as an unknown session, and the message would be about
  // a token the app never sent.
  test('no token is sent when there is no session', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([QueueEntry(position: 1, trackId: 8, title: 'a')]);
    final player = QueuePlayer(queue: queue, player: fake, session: SessionStore());
    addTearDown(player.dispose);

    await player.playCurrent();
    expect(fake.lastHeaders, isEmpty);
  });

  // The same player on a queue that came from a playlist and one that came from a single
  // song: nothing in the player knows the difference.
  test('a queue from a playlist and a queue from one song play the same way', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([QueueEntry(position: 1, trackId: 8, title: 'a')]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    expect(await player.next(), isTrue);
    expect(fake.opened, ['$apiBaseUrl/api/music/8']);

    // Nothing after it, so the player says so and stops rather than waiting for a song.
    expect(await player.next(), isFalse);
    expect(fake.stopped, ['$apiBaseUrl/api/music/8']);
  });

  // A local playlist is a list on the device. It has no server slots, but it moves on
  // when a song ends just like the server queue does.
  test('a local queue plays the next file when a song ends', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    final tracks = [
      LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
      LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
    ];

    await player.playLocalQueue(tracks);
    expect(player.localTitle, 'a.mp3');
    expect(fake.played.length, 1);

    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(player.localTitle, 'b.mp3');
    expect(fake.played.length, 2);

    // The last local song ends: the player stops instead of waiting for one that is not
    // there. The stored list is still what the queue page shows.
    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(player.localTitle, isNull);
    expect(player.localQueue.map((track) => track.title), ['a.mp3', 'b.mp3']);
    expect(fake.stopped.length, 1);
  });

  // The next button has to move a local list too, and say when it was the last song.
  test('next moves through a local list and stops at its end', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    await player.playLocalQueue([
      LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
      LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
    ]);

    expect(await player.next(), isTrue);
    expect(player.localTitle, 'b.mp3');
    expect(await player.next(), isFalse);
    expect(player.localTitle, isNull);
  });

  // A song added while another one is open has to follow it. Otherwise the queue page
  // would show the new row but the player would stop at the end of its older copy.
  test('a song added to a playing local list follows the current one', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    final first = LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));
    final second = LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));

    await player.playLocalQueue([first]);
    await player.syncLocalQueue([first, second]);

    expect(player.localTitle, 'a.mp3');
    expect(await player.next(), isTrue);
    expect(player.localTitle, 'b.mp3');
  });

  // Adding a local song while a server song plays must not turn the local list into
  // something that stops playback: nothing of it is current, so the server queue owns the
  // end of the song.
  test('a local list that is not playing does not swallow the server queue', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    await player.playCurrent();
    await player.syncLocalQueue([LocalTrack(title: 'lokal.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]))]);

    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(queue.current?.trackId, 4);
    expect(fake.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/4']);
  });

  // The player's copy may be older than the page's, so a row is dropped by its song and
  // not by a position that could point at another row.
  test('removing a local row finds it even after the order changed', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    final first = LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));
    final second = LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));

    await player.playLocalQueue([first, second]);
    await player.syncLocalQueue([second, first]);

    await player.removeLocal(second);

    expect(player.localQueue.map((track) => track.title), ['a.mp3']);
    expect(player.localTitle, 'a.mp3');
  });

  // The same song can be queued twice. Removing one row must not stop the copy that is
  // audible (it is the same object, so an identity match alone cannot tell them apart).
  test('removing one of two equal rows keeps the audible copy', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    final track = LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));
    await player.playLocalQueue([track]);
    await player.syncLocalQueue([track, track]);

    await player.removeLocal(track);

    expect(player.localTitle, 'a.mp3');
    expect(player.localQueue, hasLength(1));
    expect(fake.stopped, isEmpty);
  });

  // A file the user deleted or moved is only noticed here. It must say what is wrong and
  // must not become the song the bar names.
  test('a local file that is gone is reported and does not become current', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    await expectLater(
      player.playLocal(const LocalTrack(title: 'gone.mp3', path: '/saphire/no-such-file.mp3')),
      throwsA(isA<PlaybackException>().having((error) => error.message, 'message', contains('nicht gefunden'))),
    );

    expect(player.localTitle, isNull);
    expect(fake.opened, isEmpty);
  });

  // One file that cannot be read must not end the list: the player moves on to the next
  // one and still says which file was skipped.
  test('an auto-advance skips a local file that cannot be read', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    await player.playLocalQueue([
      LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
      const LocalTrack(title: 'gone.mp3', path: '/saphire/no-such-file.mp3'),
      LocalTrack(title: 'c.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
    ]);

    fake.complete();
    await Future<void>.delayed(Duration.zero);

    expect(player.localTitle, 'c.mp3');
    expect(fake.played, hasLength(2));
    expect(player.failure, contains('nicht gefunden'));
  });

  // The previous button is the other way through the same list. At the first row there is nothing
  // before it, so it says so and nothing is opened.
  test('previous moves back to the row before the current one', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final queue = PlaybackQueue();
    queue.fill([
      QueueEntry(position: 1, trackId: 8, title: 'a'),
      QueueEntry(position: 2, trackId: 4, title: 'b'),
    ]);
    final player = QueuePlayer(queue: queue, player: fake, session: loggedIn());
    addTearDown(player.dispose);

    await player.playCurrent();

    // The first row: nothing before it, so the player does not claim a jump it did not do.
    expect(await player.previous(), isFalse);
    expect(fake.opened, ['$apiBaseUrl/api/music/8']);
    expect(queue.current?.trackId, 8);

    expect(await player.next(), isTrue);
    expect(await player.previous(), isTrue);
    expect(queue.current?.trackId, 8);
    expect(fake.opened, ['$apiBaseUrl/api/music/8', '$apiBaseUrl/api/music/4', '$apiBaseUrl/api/music/8']);
  });

  // A local list has no slots, but it moves back the same way, and the song that is opened is the
  // file on this device — a local song has no id to ask the server for.
  test('previous moves back through a local list and opens the file on this device', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    await player.playLocalQueue([
      LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
      LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
    ]);

    await player.next();
    expect(player.localTitle, 'b.mp3');

    expect(await player.previous(), isTrue);
    expect(player.localTitle, 'a.mp3');
    // Nothing was asked from the server: the third open is the bytes of the first file.
    expect(fake.opened.last, startsWith('data:audio/mpeg'));
    expect(fake.played, hasLength(3));
  });

  // A progress bar can be dragged to its end, and a player asked past the end throws, so the jump
  // is clamped to the song.
  test('a seek past the length goes to the end and a negative one to the start', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    fake.length(const Duration(seconds: 30));

    await player.seek(const Duration(seconds: 45));
    expect(fake.sought, [const Duration(seconds: 30)]);

    await player.seek(const Duration(seconds: -5));
    expect(fake.sought.last, Duration.zero);
  });

  // The ten-second buttons move inside the song that is open, from where it currently is, and not
  // back to the start of it.
  test('skip moves from where the song currently is', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    fake.length(const Duration(seconds: 30));
    fake.at(const Duration(seconds: 10));

    await player.skip(const Duration(seconds: 10));
    expect(fake.sought, [const Duration(seconds: 20)]);

    await player.skip(const Duration(seconds: -10));
    expect(fake.sought.last, const Duration(seconds: 10));
  });

  // The slider gives its value to the player, but a value outside 0..1 is not a volume.
  test('setVolume passes the value through and clamps it', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    await player.setVolume(0.5);
    expect(fake.volumes, [0.5]);

    await player.setVolume(1.5);
    expect(fake.volumes.last, 1.0);

    await player.setVolume(-0.2);
    expect(fake.volumes.last, 0.0);
  });

  // The stored queue was reloaded and the song that is open — paused or not — is no longer
  // in it, so it must not stay the one the bar names.
  test('a song that left the local queue stops with it', () async {
    final fake = FakePlayer();
    addTearDown(fake.dispose);
    final player = QueuePlayer(queue: PlaybackQueue(), player: fake, session: SessionStore());
    addTearDown(player.dispose);

    final first = LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));
    final second = LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB]));

    await player.playLocalQueue([first]);
    await player.pause();
    await player.syncLocalQueue([second]);

    expect(player.localTitle, isNull);
    expect(fake.stopped, hasLength(1));
  });
}
