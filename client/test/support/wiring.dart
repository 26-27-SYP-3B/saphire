import 'package:dio/dio.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/storage/settings_store.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';
import 'package:saphire_client/features/playlists/data/playlist_repository.dart';
import 'package:saphire_client/features/player/data/queue_repository.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';

import 'fake_player.dart';
import 'stub_adapter.dart';

/// One set of the pieces the app wires in main.dart, but with a player that needs no
/// platform. A test that only checks the route guard needs these to exist, not to answer;
/// a test that checks what a page shows gives them adapters that answer.
class Wiring {
  Wiring(
    this.session, {
    StubAdapter? playlistAdapter,
    StubAdapter? queueAdapter,
    StubAdapter? libraryAdapter,
    SongPlayer? audio,
  }) : playlists = PlaylistRepository(dioWith(playlistAdapter), session),
       queues = QueueRepository(dioWith(queueAdapter), session),
       // A page that does not look at the library still needs the repository to exist, so
       // the default answers an empty library instead of going to the network.
       library = LibraryRepository(dioWith(libraryAdapter ?? StubAdapter(200, const [])), session) {
    // One queue and one player, the same way main.dart shares them: the page that filled
    // the list and the page that plays it look at the same object. A test that wants to
    // say "this song ended" keeps its own reference to the player it passed in.
    queue = PlaybackQueue();
    player = QueuePlayer(queue: queue, player: audio ?? FakePlayer(), session: session);
  }

  final SessionStore session;
  final PlaylistRepository playlists;
  final QueueRepository queues;
  final LibraryRepository library;

  late final PlaybackQueue queue;
  late final QueuePlayer player;

  /// Closes what a test opened: the player's subscriptions and its stream, and the audio
  /// object behind it. A test that passed its own player in still closes it separately;
  /// closing it twice is harmless.
  Future<void> dispose() => player.dispose();
}

/// A session that is still valid, so the guard lets a test reach the feature pages.
SessionStore loggedIn() =>
    SessionStore()..save('a' * 64, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);

/// The settings a returning user has: a server was saved by the first run. Through
/// save(), so the value the repositories read is set the way the app sets it. A test
/// that checks the first run builds its own empty SettingsStore.
SettingsStore withServer() => SettingsStore()..save('http://127.0.0.1:8080');

Dio dioWith(StubAdapter? adapter) => adapter == null ? Dio() : (Dio()..httpClientAdapter = adapter);
