import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/settings_store.dart';
import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/server_url_field.dart';
import '../../auth/data/auth_repository.dart';
import '../data/server_check.dart';

/// Der geführte Start beim ersten Aufruf: einen Server hinzufügen. Der Knopf
/// prüft die Adresse, 'Weiter' geht erst nach der Bestätigung zum Anmelden.
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

  /// Die Adresse, die die Prüfung bestätigt hat. 'Weiter' speichert genau diese,
  /// nicht das, was inzwischen im Feld steht.
  String? _confirmedBase;
  String? _note;

  @override
  void initState() {
    super.initState();
    // Jede Änderung am Feld macht die Bestätigung ungültig, damit 'Weiter' nie
    // eine ungeprüfte Adresse speichert.
    _url.addListener(() {
      if (_confirmedBase == null && _note == null) return;
      setState(() {
        _confirmedBase = null;
        _note = null;
      });
    });
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    // Ein leeres oder ungültiges Feld wird hier gestoppt, es geht keine Anfrage
    // weg, und das Feld behält seinen Wert für den nächsten Versuch.
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isChecking = true;
      _note = null;
      _confirmedBase = null;
    });

    final base = normalizeBase(_url.text.trim());
    final message = await checkServer(widget.dio, base);
    if (!mounted) return;
    setState(() {
      _isChecking = false;
      _confirmedBase = message == null ? base : null;
      _note = message ?? confirmedMessage;
    });
  }

  void _next() {
    final base = _confirmedBase;
    if (base == null) return;
    // Eine Session von einem früheren Server darf den Wechsel nicht überleben.
    widget.repository.logout();
    widget.settings.save(base);
    context.go('/login');
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
        if (_confirmedBase != null) ...[
          const SizedBox(height: 16),
          TextButton(onPressed: _next, child: const Text('Weiter')),
        ],
      ],
      buttonLabel: _isChecking ? 'Wird geprüft…' : 'Verbinden',
      onSubmitted: _isChecking ? null : _connect,
      note: _note,
      noteIsError: _confirmedBase == null,
    );
  }
}
