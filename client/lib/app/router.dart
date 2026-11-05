import 'package:go_router/go_router.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/register_screen.dart';

/// Anmeldung und Registrierung. Der Login ist die Startseite, von beiden Seiten
/// führt ein Link zur anderen.
GoRouter buildRouter(AuthRepository repository) {
  return GoRouter(
    initialLocation: '/login',
    routes: [
      GoRoute(path: '/login', builder: (context, state) => LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => RegisterScreen(repository: repository),
      ),
    ],
  );
}
