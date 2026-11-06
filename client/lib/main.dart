import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/storage/session_store.dart';
import 'features/auth/data/auth_repository.dart';

void main() => runApp(SaphireApp(repository: AuthRepository(Dio(), SessionStore())));
