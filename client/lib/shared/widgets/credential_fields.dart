import 'package:flutter/material.dart';

/// The two fields both auth forms show. The limits are the same as the server's
/// (see server/register.go); this only stops obvious mistakes before a request.
class CredentialFields extends StatelessWidget {
  const CredentialFields({
    super.key,
    required this.username,
    required this.password,
  });

  final TextEditingController username;
  final TextEditingController password;

  // Same pattern as server/register.go.
  static final RegExp usernamePattern = RegExp(r'^[a-z0-9_.-]+$');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(username, 'Benutzername', TextInputAction.next, (value) {
          final text = (value ?? '').trim();
          if (text.length < 3 || text.length > 32) {
            return 'Benutzername: 3 bis 32 Zeichen';
          }
          if (!usernamePattern.hasMatch(text.toLowerCase())) {
            return 'Benutzername: nur Buchstaben, Zahlen, Unterstrich, Punkt und Bindestrich';
          }
          return null;
        }),
        const SizedBox(height: 16),
        field(password, 'Passwort', TextInputAction.done, (value) {
          final text = value ?? '';
          if (text.length < 8) return 'Passwort: mindestens 8 Zeichen';
          if (text.length > 72) return 'Passwort: höchstens 72 Zeichen';
          return null;
        }, obscureText: true),
      ],
    );
  }

  Widget field(
    TextEditingController controller,
    String label,
    TextInputAction action,
    String? Function(String?) validator, {
    bool obscureText = false,
  }) {
    return TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      textInputAction: action,
      obscureText: obscureText,
      validator: validator,
    );
  }
}
