import 'package:flutter/material.dart';

import '../data/auth_repository.dart';
import '../domain/user.dart';

/// Registration form: name and email are sent to POST /api/register.
/// The fields are only checked roughly, the server decides whether an address is valid.
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
  String? _errorMessage;
  User? _registeredUser;

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
      _errorMessage = null;
    });

    try {
      final user = await widget.repository.register(
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
      );
      if (mounted) setState(() => _registeredUser = user);
    } on AuthException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorMessage = _errorMessage;
    final registeredUser = _registeredUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Register')),
      body: Form(
        key: _formKey,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Name'),
                textInputAction: TextInputAction.next,
                validator: (value) =>
                    value == null || value.trim().isEmpty ? 'Fill in your name' : null,
              ),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) =>
                    value == null || !value.contains('@') ? 'Fill in an email address' : null,
              ),
              const SizedBox(height: 16),
              if (errorMessage != null) ...[
                Text(errorMessage, style: TextStyle(color: theme.colorScheme.error)),
                const SizedBox(height: 8),
              ],
              FilledButton(
                onPressed: _isSending ? null : _register,
                child: Text(_isSending ? 'Sending…' : 'Register'),
              ),
              if (registeredUser != null) ...[
                const SizedBox(height: 16),
                Text('Account created: ${registeredUser.name} (#${registeredUser.id})'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
