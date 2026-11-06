import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/credential_fields.dart';
import '../data/auth_repository.dart';

/// Which form is shown: the same fields, a different action.
enum AuthMode { register, login }

/// The register and login window.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.repository, required this.mode});

  final AuthRepository repository;
  final AuthMode mode;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();

  bool _isSending = false;
  String? _note;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // There is no login endpoint yet, so the login button only opens the home screen.
    if (widget.mode == AuthMode.login) {
      context.go('/home');
      return;
    }

    setState(() {
      _isSending = true;
      _note = null;
    });

    try {
      await widget.repository.register(
        username: _username.text.trim(),
        password: _password.text,
      );
      if (mounted) context.go('/home');
    } on AuthException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRegister = widget.mode == AuthMode.register;

    return AuthPage(
      title: isRegister ? 'Registrieren' : 'Anmelden',
      formKey: _formKey,
      fields: [CredentialFields(username: _username, password: _password)],
      buttonLabel: _isSending ? 'Wird gesendet…' : (isRegister ? 'Registrieren' : 'Anmelden'),
      onSubmitted: _isSending ? null : _submit,
      note: _note,
      linkQuestion: isRegister ? 'Schon ein Konto?' : 'Noch kein Konto?',
      linkLabel: isRegister ? 'Anmelden' : 'Registrieren',
      linkTo: isRegister ? '/login' : '/register',
    );
  }
}
