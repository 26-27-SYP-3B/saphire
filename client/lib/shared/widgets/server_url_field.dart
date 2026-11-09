import 'package:flutter/material.dart';

import '../../features/setup/data/server_check.dart';

/// Das eine Feld, das Setup und Einstellungen zeigen: die Server-Adresse. Die
/// Limits sind dieselben wie die Prüfung in server_check.dart, ein ungültiges
/// Wort geht also nie auf die Reise.
class ServerUrlField extends StatelessWidget {
  const ServerUrlField({super.key, required this.controller, this.enabled = true});

  final TextEditingController controller;

  /// Während die Prüfung läuft, bleibt der Text stehen: sonst könnte das Feld
  /// eine andere Adresse zeigen als die, die gerade bestätigt wird.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      decoration: const InputDecoration(labelText: 'Server-Adresse'),
      validator: (value) {
        final text = (value ?? '').trim();
        if (text.isEmpty) return emptyMessage;

        final uri = Uri.tryParse(text);
        if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
          return invalidMessage;
        }
        // The path is built as base + '/api/...', so a path, query or fragment
        // in the address would be mangled into the request.
        if ((uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery || uri.hasFragment) {
          return invalidMessage;
        }
        return null;
      },
    );
  }
}
