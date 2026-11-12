import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The screens the app can move between. Every screen draws the same items from here, so
/// the labels cannot drift apart, and an item with no screen behind it stays a label
/// rather than a button. Only what has an endpoint and a screen can be opened, and that is
/// what the routes in app/router.dart are.
const navItems = [
  (label: 'Home', icon: Icons.home, to: '/home'),
  // No search screen yet, so this one stays a label.
  (label: 'Suche', icon: Icons.search, to: ''),
  (label: 'Bibliothek', icon: Icons.library_books, to: '/library'),
  (label: 'Playlists', icon: Icons.playlist_play, to: '/playlists'),
  // The queue is in the bar at the bottom, so it has no page in the navigation.
  // Alben and Künstler*innen have no screen yet, so they stay labels too.
  (label: 'Alben', icon: Icons.album, to: ''),
  (label: 'Künstler*innen', icon: Icons.people, to: ''),
];

/// The navigation, as the sidebar column or as the row a page shows at its top.
/// `selected` is the route this page is on, so the current item is the marked one and the
/// user can see where they are.
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

      final labelText = Text(label, style: theme.textTheme.labelLarge);
      final row = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: isCurrent ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          // A label that does not fit gives way, in the sidebar as in the row at the bottom.
          Flexible(child: labelText),
        ],
      );

      // Only what has a screen behind it can be tapped, and the screen the user is
      // already on is not worth sending them to again.
      return InkWell(
        onTap: to.isEmpty || isCurrent ? null : () => context.go(to),
        child: Padding(
          // The column keeps the sidebar's own indent. The row at the bottom is the one a thumb
          // aims at, so its items are 48 px tall — the smallest height a touch is aimed at without
          // missing.
          padding: vertical
              ? const EdgeInsets.fromLTRB(20, 10, 20, 10)
              : const EdgeInsets.fromLTRB(12, 14, 12, 14),
          child: row,
        ),
      );
    }

    // In the sidebar an item with no screen stays a label, because the sidebar shows what the app
    // is planned to have. In the row at the bottom such an item would be a thing that cannot be
    // tapped on a screen a person is trying to reach with one thumb, so only what leads somewhere
    // is on it.
    final entries = [for (final item in navItems) if (vertical || item.to.isNotEmpty) entry(item.label, item.icon, item.to)];

    return vertical
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: entries)
        : Row(children: [for (final row in entries) Expanded(child: row)]);
  }
}
