import 'package:flutter/material.dart';

import '../../../shared/widgets/auth_page.dart';

/// Anmeldeformular. Es zeigt Name und E-Mail, aber es gibt noch keinen
/// Login-Endpunkt auf dem Server – das Formular kann daher nichts tun außer
/// die Felder zu prüfen und darauf hinzuweisen.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  String? _note;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _login() {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _note = 'Anmelden geht noch nicht: der Server hat keinen Login-Endpunkt.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      title: 'Anmelden',
      formKey: _formKey,
      fields: [
        TextFormField(
          controller: _nameController,
          decoration: const InputDecoration(labelText: 'Name'),
          textInputAction: TextInputAction.next,
          validator: (value) => value == null || value.trim().isEmpty ? 'Name ausfüllen' : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _emailController,
          decoration: const InputDecoration(labelText: 'E-Mail'),
          keyboardType: TextInputType.emailAddress,
          validator: (value) =>
              value == null || !value.contains('@') ? 'E-Mail ausfüllen' : null,
        ),
      ],
      buttonLabel: 'Anmelden',
      onSubmitted: _login,
      note: _note,
      linkQuestion: 'Noch kein Konto?',
      linkLabel: 'Registrieren',
      linkTo: '/register',
    );
  }
}
