import 'package:go_router/go_router.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_screen.dart';
import '../features/home/presentation/home_screen.dart';

/// Anmeldung und Registrierung: gleiche Felder, zwei Routen, beide Seiten
/// verlinken sich gegenseitig. Nach einer erfolgreichen Anmeldung oder
/// Registrierung geht es auf die leere Startseite.
GoRouter buildRouter(AuthRepository repository) {
  return GoRouter(
    initialLocation: '/login',
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
        builder: (context, state) => const HomeScreen(),
      ),
    ],
  );
}
