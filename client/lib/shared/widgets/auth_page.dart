import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../shared/widgets/saphire_logo.dart';

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
    this.linkQuestion,
    this.linkLabel,
    this.linkTo,
    this.linkAction,
    this.note,
    this.noteIsError = true,
  });

  final String title;
  final GlobalKey<FormState> formKey;
  final List<Widget> fields;
  final String buttonLabel;
  final VoidCallback? onSubmitted;

  /// Der Link zur anderen Seite. Alle drei null: die Seite zeigt keinen Link.
  final String? linkQuestion;
  final String? linkLabel;
  final String? linkTo;

  /// Was der Link zusätzlich zum Gehen tun muss, zum Beispiel eine Entscheidung
  /// speichern. Null: er geht nur.
  final VoidCallback? linkAction;

  /// Was nach dem Knopf passiert ist: eine Fehlermeldung oder eine Bestätigung.
  final String? note;

  /// Eine Bestätigung ist keine Warnung und steht deshalb nicht in der Fehlerfarbe.
  final bool noteIsError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = linkLabel;

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
                    SaphireLogo(size: 120),
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
                      Text(
                        note!,
                        style: TextStyle(
                          color: noteIsError
                              ? theme.colorScheme.error
                              : theme.colorScheme.primary,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(onPressed: onSubmitted, child: Text(buttonLabel)),
                    if (label != null) ...[
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            linkQuestion ?? '',
                            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                          ),
                          TextButton(
                            onPressed: linkAction ?? (() => context.go(linkTo!)),
                            child: Text(label),
                          ),
                        ],
                      ),
                    ],
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
