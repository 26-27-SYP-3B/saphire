import 'package:flutter/material.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/register_screen.dart';

/// Root of the app. The router will come with the login screen; until then the
/// app shows the registration form directly.
class SaphireApp extends StatelessWidget {
  const SaphireApp({super.key, required this.repository});

  final AuthRepository repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Saphire',
      home: RegisterScreen(repository: repository),
    );
  }
}
