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
    this.note,
    this.footer,
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

  /// Was nach dem Knopf passiert ist: die Meldung des Servers.
  final String? note;

  /// Was unter dem Link zur anderen Seite steht: der Weg ohne Konto und ohne Server.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final label = linkLabel;

    return Scaffold(
      // A phone's status and navigation bars are not app area: without this the last row
      // can end up under the navigation bar and cannot be scrolled into view.
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
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
                              Text(note!, style: TextStyle(color: theme.colorScheme.error)),
                            ],
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(onPressed: onSubmitted, child: Text(buttonLabel)),
                            ),
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
                                    onPressed: () => context.go(linkTo!),
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
            ),
            // The way without a server is a choice on the first start, not a footnote: it is
            // pinned below the scrolling form, so a large system font or a short screen
            // cannot push it out of sight.
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: SizedBox(width: double.infinity, child: footer),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
