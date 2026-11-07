import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/storage/session_store.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/upload/data/upload_repository.dart';

// One Dio and one session, because the upload uses the same token the login got.
void main() {
  final session = SessionStore();
  final dio = Dio();

  runApp(
    SaphireApp(
      repository: AuthRepository(dio, session),
      uploads: UploadRepository(dio, session),
    ),
  );
}
