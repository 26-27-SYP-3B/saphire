import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';

/// The three screens the app moves between. Phone and desktop show the same three, because a
/// library, a search and a start page are all the navigation a client needs — like Spotify.
const navItems = [
  (label: 'Home', icon: Icons.home_filled, to: '/home'),
  (label: 'Suche', icon: Icons.search, to: '/search'),
  (label: 'Bibliothek', icon: Icons.library_books, to: '/library'),
];

/// The navigation, as the sidebar column or as the row at the bottom of a phone. `selected` is
/// the route this page is on, so the current item is marked. A destination without a screen is
/// not drawn: a label that cannot be tapped would look like a broken button.
class NavBar extends StatelessWidget {
  const NavBar({super.key, required this.selected, this.vertical = true});

  final String selected;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget entry(String label, IconData icon, String to) {
      final isCurrent = to == selected;

      final row = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 22,
            color: isCurrent ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: isCurrent ? scheme.onSurface : scheme.onSurfaceVariant,
                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ),
        ],
      );

      return Semantics(
        button: true,
        selected: isCurrent,
        child: InkWell(
          onTap: isCurrent ? null : () => context.go(to),
          borderRadius: BorderRadius.circular(6),
          hoverColor: hover,
          child: Padding(
            padding: vertical
                ? const EdgeInsets.fromLTRB(12, 10, 12, 10)
                : const EdgeInsets.symmetric(horizontal: 8, vertical: 13),
            child: row,
          ),
        ),
      );
    }

    return vertical
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // A desktop reaches the library through "Deine Bibliothek" below, the way
              // Spotify's sidebar does; only the phone has a Bibliothek tab.
              for (final item in navItems)
                if (item.to != '/library')
                  entry(item.label, item.icon, item.to),
            ],
          )
        : Row(
            children: [
              for (final item in navItems)
                Expanded(
                  child: Center(child: entry(item.label, item.icon, item.to)),
                ),
            ],
          );
  }
}
