import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/storage/session_store.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/library/data/library_repository.dart';
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
  // of asking for the password again.
  final session = await SessionStore.restore();
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
    ),
  );
}
