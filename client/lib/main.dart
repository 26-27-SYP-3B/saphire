import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'app/app.dart';
import 'features/auth/data/auth_repository.dart';

void main() => runApp(SaphireApp(repository: AuthRepository(Dio())));
