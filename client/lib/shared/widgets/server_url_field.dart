import 'package:flutter/material.dart';

import '../../features/setup/data/server_check.dart';

/// The one field that setup and settings show: the server address. The
/// limits are the same as the check in server_check.dart, so an invalid
/// word never starts the journey.
class ServerUrlField extends StatelessWidget {
  const ServerUrlField({super.key, required this.controller, this.enabled = true});

  final TextEditingController controller;

  /// While the check runs, the text stays put: otherwise the field could
  /// show a different address than the one being confirmed right now.
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
