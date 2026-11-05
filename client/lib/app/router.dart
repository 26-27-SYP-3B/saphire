import 'package:go_router/go_router.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/auth_screen.dart';

/// Anmeldung und Registrierung: gleiche Felder, zwei Routen, beide Seiten
/// verlinken sich gegenseitig.
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
    ],
  );
}
