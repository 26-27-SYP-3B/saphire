import 'package:go_router/go_router.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/upload/data/upload_repository.dart';

/// Anmeldung und Registrierung: gleiche Felder, zwei Routen, beide Seiten
/// verlinken sich gegenseitig. Nach einer erfolgreichen Anmeldung oder
/// Registrierung geht es auf die Startseite – aber nur mit einer gültigen
/// Session, ohne sie bleibt die app auf der Anmeldung.
GoRouter buildRouter(AuthRepository repository, UploadRepository uploads) {
  return GoRouter(
    initialLocation: '/login',
    redirect: (context, state) {
      final goingHome = state.matchedLocation == '/home';
      if (goingHome && !repository.session.isLoggedIn) {
        return '/login';
      }
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
        builder: (context, state) => HomeScreen(repository: repository, uploads: uploads),
      ),
    ],
  );
}
