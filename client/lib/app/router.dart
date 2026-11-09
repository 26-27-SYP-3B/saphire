import 'package:go_router/go_router.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/library/data/library_repository.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/player/data/player.dart';
import '../features/playlists/data/playlist_store.dart';
import '../features/upload/data/upload_repository.dart';

/// Anmeldung und Registrierung: gleiche Felder, zwei Routen, beide Seiten
/// verlinken sich gegenseitig. Nach einer erfolgreichen Anmeldung oder
/// Registrierung geht es auf die Startseite – aber nur mit einer gültigen
/// Session, ohne sie bleibt die app auf der Anmeldung.
GoRouter buildRouter(
  AuthRepository repository,
  UploadRepository uploads,
  LibraryRepository library,
  PlaylistStore playlists,
  Player player,
) {
  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final loggedIn = repository.session.isLoggedIn;
      final atAuthPage = state.matchedLocation == '/login' || state.matchedLocation == '/register';
      // A session restored from the last run skips the form; a browser that
      // reloads on the login page has no session left and stays there.
      if (loggedIn && atAuthPage) return '/home';
      if (!loggedIn && !atAuthPage) return '/login';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => AuthScreen(repository: repository, mode: AuthMode.login),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => AuthScreen(repository: repository, mode: AuthMode.register),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) => HomeScreen(
          repository: repository,
          uploads: uploads,
          player: player,
        ),
      ),
      GoRoute(
        path: '/library',
        builder: (context, state) => LibraryScreen(
          library: library,
          player: player,
          playlists: playlists,
          uploads: uploads,
        ),
      ),
    ],
  );
}
