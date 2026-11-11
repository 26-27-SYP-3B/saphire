import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/settings_store.dart';
import '../../../shared/widgets/auth_page.dart';
import '../../../shared/widgets/credential_fields.dart';
import '../data/auth_repository.dart';

/// Which form is shown: the same fields, a different action.
enum AuthMode { register, login }

/// The register and login window.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.repository, required this.mode, this.settings});

  final AuthRepository repository;
  final AuthMode mode;

  /// What the app remembers about running without a server. A test that only checks the
  /// form can leave it out; the store then stays in memory.
  final SettingsStore? settings;

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

    // The server normalizes usernames to lowercase; we send the same form so
    // what the user typed and what the app stores are always the same name.
    final username = _username.text.trim().toLowerCase();

    setState(() {
      _isSending = true;
      _note = null;
    });

    try {
      if (widget.mode == AuthMode.register) {
        await widget.repository.register(username: username, password: _password.text);
        // Registration does not create a session on the server, so we log in
        // with the same credentials before opening the home screen.
        await widget.repository.login(username: username, password: _password.text);
      } else {
        await widget.repository.login(username: username, password: _password.text);
      }
      // A login is the way out of local mode, so the guard lets the next restart start
      // on the login form again instead of opening the home screen without an account.
      await widget.settings?.save(localMode: false);
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
      // The way into local mode: no account, no server, the songs from the device. The
      // guided setup (a later screen) lands in the same place.
      footer: TextButton(
        onPressed: () async {
          await widget.settings?.save(localMode: true);
          if (!context.mounted) return;
          context.go('/home');
        },
        child: const Text('Ohne Server fortfahren'),
      ),
    );
  }
}
