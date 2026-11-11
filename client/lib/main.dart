import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/storage/session_store.dart';
import 'core/storage/settings_store.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/library/data/local_library.dart';
import 'features/playlists/data/cover_store.dart';
import 'features/playlists/data/playlist_repository.dart';
import 'features/player/data/just_audio_player.dart';
import 'features/player/data/queue_repository.dart';
import 'features/player/domain/player.dart';
import 'features/player/domain/queue.dart';
import 'features/upload/data/upload_repository.dart';

// One Dio and one session, because the upload uses the same token the login got.
// One queue and one player for the same reason: the playlist page fills the queue and the
// player page plays it, so both have to be looking at the same list.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A session from the last run means the app opens on the home screen instead
  // of asking for the password again. A server the guided setup saved on the first run is
  // the server of this run, and the settings also say whether the user chose to run
  // without one; the local library is what that home screen then shows.
  final session = await SessionStore.restore();
  final settings = await SettingsStore.restore();
  final localLibrary = await LocalLibrary.restore();
  // The covers belong to this device, like the local library, so they are restored here.
  final covers = await CoverStore.restore();
  final dio = Dio();

  final queue = PlaybackQueue();
  final player = JustAudioPlayer();

  runApp(
    SaphireApp(
      repository: AuthRepository(dio, session),
      uploads: UploadRepository(dio, session),
      library: LibraryRepository(dio, session),
      playlists: PlaylistRepository(dio, session),
      queues: QueueRepository(dio, session),
      queue: queue,
      player: QueuePlayer(queue: queue, player: player, session: session),
      session: session,
      settings: settings,
      localLibrary: localLibrary,
      covers: covers,
      dio: dio,
    ),
  );
}
