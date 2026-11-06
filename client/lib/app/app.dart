import 'package:flutter/material.dart';

import '../features/auth/data/auth_repository.dart';
import 'router.dart';
import 'theme.dart';

/// Root of the app: the theme and the two auth routes.
class SaphireApp extends StatelessWidget {
  const SaphireApp({super.key, required this.repository});

  final AuthRepository repository;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Saphire',
      theme: buildTheme(),
      routerConfig: buildRouter(repository),
    );
  }
}
