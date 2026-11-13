import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'app/app.dart';
import 'core/storage/session_store.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/library/data/library_repository.dart';
import 'features/player/data/just_audio_engine.dart';
import 'features/player/domain/player.dart';
import 'features/upload/data/upload_repository.dart';

// One Dio and one session, because the upload, the library and the player all use the
// same token the login got.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A session from the last run means the app opens on the home screen instead
  // of asking for the password again.
  final session = await SessionStore.restore();
  final dio = Dio();

  runApp(
    SaphireApp(
      repository: AuthRepository(dio, session),
      uploads: UploadRepository(dio, session),
      library: LibraryRepository(dio, session),
      player: Player(JustAudioEngine(AudioPlayer()), session),
    ),
  );
}
