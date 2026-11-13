import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'saphire_logo.dart';

/// The navigation, shared by the pages so the app has one shape instead of two copies of
/// it.
///
/// Only a page that exists is a link. 'Suche' and the sections below stay labels, because
/// those areas have no endpoints yet (api-docs.md, Upcoming): something that is not a
/// button does not pretend to be one.
class SaphireSidebar extends StatelessWidget {
  const SaphireSidebar({
    required this.selected,
    required this.height,
    this.extraSections = const [],
    super.key,
  });

  final String selected;
  final double height;
  final List<Widget> extraSections;

  static const _items = [
    (label: 'Home', icon: Icons.home, route: '/home'),
    (label: 'Suche', icon: Icons.search, route: null),
    (label: 'Bibliothek', icon: Icons.library_books, route: '/library'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 248,
      height: height,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The lines in the logo asset are thin, so at this size they come out
            // soft — that is the small mark the mock shows.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SaphireLogo(size: 44),
            ),
            for (final item in _items) _navItem(context, item, selected: item.route == selected),
            ...extraSections,
          ],
        ),
      ),
    );
  }

  Widget _navItem(BuildContext context, ({String label, IconData icon, String? route}) item, {bool selected = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final content = Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Icon(item.icon, size: 20, color: selected ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Flexible(child: Text(item.label, style: theme.textTheme.labelLarge)),
        ],
      ),
    );

    if (item.route == null) return content;
    return InkWell(onTap: () => context.go(item.route!), child: content);
  }
}
