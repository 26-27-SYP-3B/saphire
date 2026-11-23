import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/api_config.dart';
import '../../../core/storage/settings_store.dart';
import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/server_url_field.dart';
import '../../auth/data/auth_repository.dart';
import '../data/server_check.dart';

/// The settings, reached through the profile menu: a new server address,
/// checked and saved like in the setup, then sign in at that server.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.repository,
    required this.dio,
  });

  final SettingsStore settings;
  final AuthRepository repository;
  final Dio dio;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _url;

  bool _isChecking = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    // The field shows the address currently in use. Without a saved address
    // that is the start value from --dart-define.
    _url = TextEditingController(text: widget.settings.serverBase ?? apiBaseUrl);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _changeServer() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isChecking = true;
      _note = null;
    });

    final base = normalizeBase(_url.text.trim());

    // The same address is no change: no request goes out, and the session
    // stays where it is.
    if (base.toLowerCase() == widget.settings.serverBase?.toLowerCase()) {
      context.go('/home');
      return;
    }

    final message = await checkServer(widget.dio, base);
    if (!mounted) return;
    setState(() => _isChecking = false);

    if (message != null) {
      setState(() => _note = message);
      return;
    }

    // The old session belongs to the old server, so log in again.
    await widget.repository.logout();
    // A server replaces the start without a server, otherwise the next start would stay there.
    await widget.settings.save(server: base, localMode: false);
    if (!mounted) return;
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      title: 'Einstellungen',
      formKey: _formKey,
      fields: [ServerUrlField(controller: _url, enabled: !_isChecking)],
      buttonLabel: _isChecking ? 'Wird geprüft…' : 'Server ändern',
      onSubmitted: _isChecking ? null : _changeServer,
      note: _note,
      // Without this way the page would be a dead end: the only button leads
      // beyond the server change.
      linkQuestion: 'Nichts ändern?',
      linkLabel: 'Zurück',
      linkTo: '/home',
    );
  }
}
