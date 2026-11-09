import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
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
}
