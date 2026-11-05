import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/credential_fields.dart';
import '../data/auth_repository.dart';

/// Which form is shown: the same fields, a different call to the server.
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
  final _identity = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _isSending = false;
  String? _note;

  @override
  void dispose() {
    _identity.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSending = true;
      _note = null;
    });

    final identity = _identity.text.trim();
    final password = _password.text;

    try {
      if (widget.mode == AuthMode.register) {
        await widget.repository.register(username: identity, email: _email.text.trim(), password: password);
      } else {
        await widget.repository.login(login: identity, password: password);
      }

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
      fields: [
        CredentialFields(
          identity: _identity,
          identityLabel: isRegister ? 'Benutzername' : 'Benutzername oder E-Mail',
          showEmail: isRegister,
          email: _email,
          password: _password,
        ),
      ],
      buttonLabel: _isSending ? 'Wird gesendet…' : (isRegister ? 'Registrieren' : 'Anmelden'),
      onSubmitted: _isSending ? null : _submit,
      note: _note,
      linkQuestion: isRegister ? 'Schon ein Konto?' : 'Noch kein Konto?',
      linkLabel: isRegister ? 'Anmelden' : 'Registrieren',
      linkTo: isRegister ? '/login' : '/register',
    );
  }
}
