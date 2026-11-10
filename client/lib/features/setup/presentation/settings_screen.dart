import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/api_config.dart';
import '../../../core/storage/settings_store.dart';
import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/server_url_field.dart';
import '../../auth/data/auth_repository.dart';
import '../data/server_check.dart';

/// Die Einstellungen, erreicht über das Profilmenü: eine neue Server-Adresse,
/// geprüft und gespeichert wie im Setup, dann Anmelden an diesem Server.
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
    // Das Feld zeigt die Adresse, die gerade in Gebrauch ist. Ohne gespeicherte
    // Adresse ist das der Startwert aus --dart-define.
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

    // Die gleiche Adresse ist keine Änderung: es geht keine Anfrage weg, und die
    // Session bleibt, wo sie ist.
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

    // Die alte Session gehört zum alten Server, also meldet man sich neu an.
    await widget.repository.logout();
    await widget.settings.save(base);
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
      // Ohne diesen Weg wäre die Seite eine Sackgasse: der einzige Knopf führt
      // über den Serverwechsel hinaus.
      linkQuestion: 'Nichts ändern?',
      linkLabel: 'Zurück',
      linkTo: '/home',
    );
  }
}
