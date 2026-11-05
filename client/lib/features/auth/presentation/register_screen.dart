import 'package:flutter/material.dart';

import '../../../shared/widgets/auth_page.dart';
import '../data/auth_repository.dart';

/// Registrierungsformular: Name und E-Mail werden an POST /api/register gesendet.
/// Die Felder werden nur grob geprüft, ob eine E-Mail gültig ist entscheidet der Server.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.repository});

  final AuthRepository repository;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();

  bool _isSending = false;
  String? _note;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSending = true;
      _note = null;
    });

    try {
      final user = await widget.repository.register(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
      );
      if (mounted) setState(() => _note = 'Konto erstellt: ${user.name} (#${user.id})');
    } on AuthException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthPage(
      title: 'Registrieren',
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
      buttonLabel: _isSending ? 'Wird gesendet…' : 'Registrieren',
      onSubmitted: _isSending ? null : _register,
      note: _note,
      linkQuestion: 'Schon ein Konto?',
      linkLabel: 'Anmelden',
      linkTo: '/login',
    );
  }
}
