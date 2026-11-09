import 'package:flutter/material.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/library/data/library_repository.dart';
import '../features/playlists/data/playlist_store.dart';
import '../features/player/data/player.dart';
import '../features/upload/data/upload_repository.dart';
import 'router.dart';
import 'theme.dart';

/// Root of the app: the theme and the routes.
class SaphireApp extends StatelessWidget {
  const SaphireApp({
    super.key,
    required this.repository,
    required this.uploads,
    required this.library,
    required this.playlists,
    required this.player,
  });

  final AuthRepository repository;
  final UploadRepository uploads;
  final LibraryRepository library;
  final PlaylistStore playlists;
  final Player player;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Saphire',
      theme: buildTheme(),
      routerConfig: buildRouter(repository, uploads, library, playlists, player),
    );
  }
}
