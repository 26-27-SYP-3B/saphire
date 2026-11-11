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
          // The sidebar has a fixed width, so a long label has to give way; the row that
          // scrolls sideways sizes itself and must not hold a flex child.
          if (vertical) Flexible(child: labelText) else labelText,
        ],
      );

      // Only what has a screen behind it can be tapped, and the screen the user is
      // already on is not worth sending them to again.
      return InkWell(
        onTap: to.isEmpty || isCurrent ? null : () => context.go(to),
        child: Padding(
          // The column keeps the sidebar's own indent; a row starts at the margin the
          // page already uses, so its first item lines up with the content below it.
          padding: vertical
              ? const EdgeInsets.fromLTRB(20, 10, 20, 10)
              : const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: row,
        ),
      );
    }

    final entries = [for (final item in navItems) entry(item.label, item.icon, item.to)];

    // The row of a narrow page scrolls sideways: with every item on it, a phone is
    // narrower than the list, and an overflowing Row throws instead of scrolling.
    return vertical
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: entries)
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(mainAxisSize: MainAxisSize.min, children: entries),
          );
  }
}
