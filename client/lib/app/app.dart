import 'package:flutter/material.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/upload/data/upload_repository.dart';
import 'router.dart';
import 'theme.dart';

/// Root of the app: the theme and the routes.
class SaphireApp extends StatelessWidget {
  const SaphireApp({super.key, required this.repository, required this.uploads});

  final AuthRepository repository;
  final UploadRepository uploads;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Saphire',
      theme: buildTheme(),
      routerConfig: buildRouter(repository, uploads),
    );
  }
}
