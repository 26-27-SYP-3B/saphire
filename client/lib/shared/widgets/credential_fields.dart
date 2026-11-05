import 'package:flutter/material.dart';

/// The three fields both auth forms show: username, email, password.
/// The limits are here once, so registration and login check the same values.
/// The server is the trust boundary; these checks only stop obvious mistakes
/// before a request is sent.
class CredentialFields extends StatelessWidget {
  const CredentialFields({
    super.key,
    required this.username,
    required this.email,
    required this.password,
  });

  final TextEditingController username;
  final TextEditingController email;
  final TextEditingController password;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(username, 'Benutzername', TextInputAction.next, (value) =>
            value == null || value.trim().length < 3 ? 'Benutzername: mindestens 3 Zeichen' : null),
        const SizedBox(height: 16),
        field(email, 'E-Mail', TextInputAction.next, (value) =>
            value == null || !value.contains('@') ? 'E-Mail ausfüllen' : null,
            keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 16),
        field(password, 'Passwort', TextInputAction.done, (value) =>
            value == null || value.length < 8 ? 'Passwort: mindestens 8 Zeichen' : null,
            obscureText: true),
      ],
    );
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
