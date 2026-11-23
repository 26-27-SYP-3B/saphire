import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/settings_store.dart';
import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/server_url_field.dart';
import '../../auth/data/auth_repository.dart';
import '../data/server_check.dart';

/// The guided start on the first call: add a server. 'Connect' checks the
/// address and leads straight to the login on a confirmation.
class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.settings,
    required this.repository,
    required this.dio,
  });

  final SettingsStore settings;
  final AuthRepository repository;
  final Dio dio;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _url = TextEditingController();

  bool _isChecking = false;
  String? _note;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    // An empty or invalid field is stopped here, no request goes out, and the
    // field keeps its value for the next attempt.
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isChecking = true;
      _note = null;
    });

    final base = normalizeBase(_url.text.trim());
    final message = await checkServer(widget.dio, base);
    if (!mounted) return;

    if (message != null) {
      setState(() {
        _isChecking = false;
        _note = message;
      });
      return;
    }

    // A session from an earlier server must not survive the switch.
    await widget.repository.logout();
    // A server replaces the start without a server, otherwise the next start would stay there.
    await widget.settings.save(server: base, localMode: false);
    if (!mounted) return;
    context.go('/login');
  }

  /// The way without a server, straight from the first start: no account, the songs of this device.
  Future<void> _withoutServer() async {
    // A session belongs to a server that this start does not use.
    await widget.repository.logout();
    await widget.settings.save(localMode: true);
    if (!mounted) return;
    context.go('/home');
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      title: 'Willkommen bei Saphire',
      formKey: _formKey,
      fields: [
        Text('Gib die Adresse deines Saphire-Servers ein.'),
        const SizedBox(height: 16),
        ServerUrlField(controller: _url, enabled: !_isChecking),
      ],
      buttonLabel: _isChecking ? 'Wird geprüft…' : 'Verbinden',
      onSubmitted: _isChecking ? null : _connect,
      note: _note,
      footer: TextButton(
        onPressed: _isChecking ? null : _withoutServer,
        child: const Text('Weiter ohne Server'),
      ),
    );
  }
}
