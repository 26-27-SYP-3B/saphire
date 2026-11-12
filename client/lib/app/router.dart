import 'package:dio/dio.dart';
import 'package:go_router/go_router.dart';

import '../core/storage/session_store.dart';
import '../core/storage/settings_store.dart';
import '../core/utils/pick_image.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/library/data/library_repository.dart';
import '../features/library/data/local_library.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/playlists/data/cover_store.dart';
import '../features/playlists/data/playlist_repository.dart';
import '../features/playlists/presentation/playlists_screen.dart';
import '../features/player/data/queue_repository.dart';
import '../features/player/domain/player.dart';
import '../features/player/domain/queue.dart';
import '../features/setup/presentation/settings_screen.dart';
import '../features/setup/presentation/setup_screen.dart';
import '../features/upload/data/upload_repository.dart';

/// Anmeldung und Registrierung: gleiche Felder, zwei Routen, beide Seiten
/// verlinken sich gegenseitig. Nach einer erfolgreichen Anmeldung oder
/// Registrierung geht es auf die Startseite – aber nur mit einer gültigen
/// Session, ohne sie bleibt die app auf der Anmeldung. Im lokalen Modus gibt es
/// kein Konto, dort ist die Startseite ohne Session offen.
///
/// Der geführte Start gehört vor die Anmeldung: ohne gespeicherten Server führt
/// kein Weg am Setup vorbei, mit ihm öffnet sich die app direkt wie früher.
///
/// The queue and the player are passed in, not created here: one queue and one player
/// belong to the whole app, so the bar at the bottom of every page shows the same list a
/// playlist just filled. A route that made its own queue would lose it on the next
/// navigation.
GoRouter buildRouter({
  required AuthRepository auth,
  required UploadRepository uploads,
  required LibraryRepository library,
  required PlaylistRepository playlists,
  required QueueRepository queues,
  required PlaybackQueue queue,
  required QueuePlayer player,
  required SessionStore session,
  SettingsStore? settings,
  LocalLibrary? localLibrary,
  CoverStore? covers,
  PickImage? pickImage,
  required Dio dio,
}) {
  final settingsStore = settings ?? SettingsStore();

  return GoRouter(
    // Without a stored server there is nothing to log in to, so the app starts on the
    // home screen only when the user chose to run without one.
    initialLocation: settingsStore.localMode
        ? '/home'
        : (settingsStore.serverBase == null ? '/setup' : '/login'),
    redirect: (context, state) {
      // Without a stored server there is nothing to log in to, so every other
      // address – a web reload of /login included – belongs in the setup. Local mode
      // has no server by design, so it is not sent there.
      if (!settingsStore.localMode && settingsStore.serverBase == null && state.matchedLocation != '/setup') {
        return '/setup';
      }
      final loggedIn = session.isLoggedIn;
      final atAuthPage = state.matchedLocation == '/login' || state.matchedLocation == '/register';
      // A session restored from the last run skips the form; a browser that
      // reloads on the login page has no session left and stays there.
      if (loggedIn && atAuthPage) return '/home';
      // The setup is the page that finds the first server, so it stays reachable
      // without a session – and so does the home screen in local mode.
      if (!loggedIn && !atAuthPage && state.matchedLocation != '/setup' && !settingsStore.localMode) {
        return '/login';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/setup',
        builder: (context, state) => SetupScreen(settings: settingsStore, repository: auth, dio: dio),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => SettingsScreen(settings: settingsStore, repository: auth, dio: dio),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => AuthScreen(repository: auth, mode: AuthMode.login, settings: settingsStore),
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => AuthScreen(repository: auth, mode: AuthMode.register, settings: settingsStore),
      ),
      GoRoute(
        path: '/home',
        // The home page's bar shows the shared queue and player rather than a second set
        // built for this page.
        builder: (context, state) => HomeScreen(
          repository: auth,
          uploads: uploads,
          library: library,
          queues: queues,
          playlists: playlists,
          session: session,
          player: player,
          settings: settingsStore,
          localLibrary: localLibrary,
        ),
      ),
      GoRoute(
        path: '/playlists',
        builder: (context, state) => PlaylistsScreen(
          playlists: playlists,
          library: library,
          queues: queues,
          queue: queue,
          player: player,
          session: session,
          pickImage: pickImage ?? pickImageFile,
          settings: settingsStore,
          localLibrary: localLibrary,
          covers: covers,
        ),
      ),
      GoRoute(
        path: '/library',
        // The page plays through the shared queue and shows the bar that opens it, so it
        // gets the app's one queue and player rather than its own.
        builder: (context, state) => LibraryScreen(
          library: library,
          playlists: playlists,
          queues: queues,
          queue: queue,
          player: player,
          uploads: uploads,
          session: session,
          settings: settingsStore,
          localLibrary: localLibrary,
        ),
      ),
    ],
  );
}
