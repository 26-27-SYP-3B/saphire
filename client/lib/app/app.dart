import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../core/storage/session_store.dart';
import '../core/storage/settings_store.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/library/data/library_repository.dart';
import '../features/library/data/local_library.dart';
import '../features/playlists/data/playlist_repository.dart';
import '../features/player/data/queue_repository.dart';
import '../features/player/domain/player.dart';
import '../features/player/domain/queue.dart';
import '../features/upload/data/upload_repository.dart';
import 'router.dart';
import 'theme.dart';

/// Root of the app: the theme and the routes.
///
/// The queue and the player are given in rather than built here. One queue and one player
/// belong to the whole app, so the page that opened the queue from a playlist shows the
/// same list it just filled — a screen with its own queue would lose it on the next
/// navigation.
class SaphireApp extends StatefulWidget {
  const SaphireApp({
    super.key,
    required this.repository,
    required this.uploads,
    required this.library,
    required this.playlists,
    required this.queues,
    required this.queue,
    required this.player,
    required this.session,
    SettingsStore? settings,
    LocalLibrary? localLibrary,
    required this.dio,
  });

  final AuthRepository repository;
  final UploadRepository uploads;
  final LibraryRepository library;
  final PlaylistRepository playlists;
  final QueueRepository queues;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;
  final Dio dio;

  @override
  State<SaphireApp> createState() => _SaphireAppState();
}

class _SaphireAppState extends State<SaphireApp> {
  @override
  void dispose() {
    // The app lives as long as the player and the stream the queue player holds. Nothing
    // else in the app has an exit path, so this is where the audio object is released.
    widget.player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Saphire',
      theme: buildTheme(),
      routerConfig: buildRouter(
        auth: widget.repository,
        uploads: widget.uploads,
        library: widget.library,
        playlists: widget.playlists,
        queues: widget.queues,
        queue: widget.queue,
        player: widget.player,
        session: widget.session,
        settings: widget.settings,
        localLibrary: widget.localLibrary,
        dio: widget.dio,
      ),
    );
  }
}
