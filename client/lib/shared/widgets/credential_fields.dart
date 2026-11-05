import 'package:flutter/material.dart';

/// The fields both auth forms show. The first field is the identity: a username,
/// or an address when it contains an @. The email field only exists at register.
/// The server is the trust boundary; these checks only stop obvious mistakes
/// before a request is sent, and they use the same limits as the server.
class CredentialFields extends StatelessWidget {
  const CredentialFields({
    super.key,
    required this.identity,
    required this.identityLabel,
    required this.showEmail,
    required this.email,
    required this.password,
  });

  final TextEditingController identity;
  final String identityLabel;
  final bool showEmail;
  final TextEditingController email;
  final TextEditingController password;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(identity, identityLabel, TextInputAction.next, identityError),
        if (showEmail) ...[
          const SizedBox(height: 16),
          field(email, 'E-Mail', TextInputAction.next,
              (value) => _looksLikeAddress(value) ? null : 'E-Mail ausfüllen',
              keyboardType: TextInputType.emailAddress),
        ],
        const SizedBox(height: 16),
        field(password, 'Passwort', TextInputAction.done,
            (value) => (value ?? '').length < 8 ? 'Passwort: mindestens 8 Zeichen' : null,
            obscureText: true),
      ],
    );
  }

  String? identityError(String? value) {
    final text = (value ?? '').trim();
    if (text.contains('@')) return _looksLikeAddress(text) ? null : 'Das ist keine Adresse';
    return text.length < 3 ? 'Benutzername: mindestens 3 Zeichen' : null;
  }

  bool _looksLikeAddress(String? value) {
    final text = value ?? '';
    return text.contains('@') && text.split('@').last.contains('.');
  }

  Widget field(
    TextEditingController controller,
    String label,
    TextInputAction action,
    String? Function(String?) validator, {
    TextInputType? keyboardType,
    bool obscureText = false,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      textInputAction: action,
      keyboardType: keyboardType,
      obscureText: obscureText,
      validator: validator,
    );
  }
}
