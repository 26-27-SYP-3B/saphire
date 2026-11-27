import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// The square a song or a playlist shows: the cover its tags carry, or the app's own mark when
/// it has none. Every list, the bar and the full player draw the same square, so a song looks
/// the same wherever it appears.
class TrackArt extends StatelessWidget {
  const TrackArt({
    super.key,
    this.cover,
    this.size = 48,
    this.radius = 6,
    this.icon = Icons.music_note,
  });

  final Uint8List? cover;
  final double size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final image = cover;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: fieldBackground,
        child: image == null
            ? Icon(icon, size: size * 0.42, color: mutedText)
            : Image.memory(
                image,
                fit: BoxFit.cover,
                // A full photo is decoded at thumbnail size, not at its own.
                cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                    .round(),
                // A stored cover that cannot be decoded shows the mark, not an exception.
                errorBuilder: (context, error, stack) =>
                    Icon(icon, size: size * 0.42, color: mutedText),
              ),
      ),
    );
  }
}

/// The small line that says where a row came from. It is not a button; it is what tells a song
/// on this device apart from one of the shared library.
class SourceBadge extends StatelessWidget {
  const SourceBadge({super.key, required this.local});

  final bool local;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: local
            ? scheme.primary.withValues(alpha: 0.18)
            : Colors.transparent,
        border: Border.all(color: local ? scheme.primary : scheme.outline),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        local ? 'Lokal' : 'Server',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: local ? scheme.primary : scheme.onSurfaceVariant),
      ),
    );
  }
}
