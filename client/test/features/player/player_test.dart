import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/library/domain/library_entry.dart';
import 'package:saphire_client/features/player/domain/player.dart';

import '../../support/fake_engine.dart';

SessionStore loggedIn() =>
    SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

final song = LibraryEntry(id: 4, title: 'lied.wav');

void main() {
  // The library answer has no file path, so the id is the whole way to a song.
  test('a song is reached through its id', () async {
    final engine = FakeEngine();
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.playSong(song);

    expect(engine.opened, ['$apiBaseUrl/api/music/4']);
  });

  test('the stream request carries the session token', () async {
    final engine = FakeEngine();
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.playSong(song);

    expect(engine.sentHeaders.first['Authorization'], 'Bearer ${'a' * 64}');
  });

  test('nothing is played before a song is chosen', () async {
    final engine = FakeEngine();
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.toggle();

    expect(engine.calls, isEmpty);
  });

  test('play and pause go through the engine', () async {
    final engine = FakeEngine();
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.playSong(song);
    await player.toggle();

    expect(engine.calls, ['open', 'play', 'pause']);
  });

  test('a seek asks for a position, which is a new request for a byte range', () async {
    final engine = FakeEngine();
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.playSong(song);
    await player.seekTo(Duration(seconds: 30));

    expect(engine.calls, contains('seek'));
  });

  test('what a widget sees is the song, whether it plays, and how far it is', () async {
    final engine = FakeEngine();
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.playSong(song);
    engine.report(Duration(seconds: 12), Duration(seconds: 90));
    await Future(() {}); // the engine answers through its streams

    final state = player.current;
    expect(state.song?.title, 'lied.wav');
    expect(state.playing, true);
    expect(state.position, Duration(seconds: 12));
    expect(state.duration, Duration(seconds: 90));
  });

  // A stream that stops early cannot be reported as a status any more, so the message is
  // what the bar has to show.
  test('a stream that cannot be opened keeps the message instead of an empty bar', () async {
    final engine = FakeEngine(openError: 'the file for this song is not in the library folder');
    final player = Player(engine, loggedIn());
    addTearDown(player.dispose);

    await player.playSong(LibraryEntry(id: 9, title: 'fehlt.mp3'));

    expect(player.current.song?.title, 'fehlt.mp3');
    expect(player.current.error, 'the file for this song is not in the library folder');
  });
}
