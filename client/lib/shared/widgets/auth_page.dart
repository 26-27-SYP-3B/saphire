import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

/// Gemeinsames Layout für Anmeldung und Registrierung: dunkle Fläche, schmale Spalte,
/// Markenname oben, dann Überschrift, Felder, Knopf und der Link zur anderen Seite.
class AuthPage extends StatelessWidget {
  const AuthPage({
    super.key,
    required this.title,
    required this.formKey,
    required this.fields,
    required this.buttonLabel,
    required this.onSubmitted,
    required this.linkQuestion,
    required this.linkLabel,
    required this.linkTo,
    this.note,
  });

  final String title;
  final GlobalKey<FormState> formKey;
  final List<Widget> fields;
  final String buttonLabel;
  final VoidCallback? onSubmitted;
  final String linkQuestion;
  final String linkLabel;
  final String linkTo;

  /// Was nach dem Knopf passiert ist: eine Fehlermeldung oder eine Bestätigung.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          // Ohne feste Breite hätten die Felder hier keinen begrenzten Platz.
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columnWidth =
                  constraints.maxWidth < 340.0 ? constraints.maxWidth : 340.0;

              return SizedBox(
                width: columnWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SvgPicture.asset(
                      'assets/saphire_logo.svg',
                      height: 44,
                      semanticsLabel: 'Saphire',
                    ),
                    const SizedBox(height: 28),
                    Text(title, style: theme.textTheme.displaySmall),
                    const SizedBox(height: 28),
                    Form(
                      key: formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: fields,
                      ),
                    ),
                    if (note != null) ...[
                      const SizedBox(height: 16),
                      Text(note!, style: TextStyle(color: theme.colorScheme.error)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(onPressed: onSubmitted, child: Text(buttonLabel)),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          linkQuestion,
                          style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                        ),
                        TextButton(
                          onPressed: () => context.go(linkTo),
                          child: Text(linkLabel),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
