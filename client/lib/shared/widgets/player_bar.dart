import 'package:flutter/material.dart';

import '../../features/player/data/player.dart';

/// The bar every screen shows at the bottom: what is playing, and what would come
/// next from the queue. It is the same widget on every page, so it listens to the
/// player instead of keeping its own copy of what is playing.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final playing = player.current;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outline))),
          child: Row(
            children: [
              Icon(playing == null ? Icons.audio_file : Icons.play_arrow,
                  size: 22, color: playing == null ? scheme.onSurfaceVariant : scheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      playing == null ? 'Nichts wird abgespielt' : playing.title,
                      style: theme.textTheme.labelLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      // What the bar says about the next song, so adding one to the
                      // queue can be seen without a queue screen.
                      player.error ??
                          (player.queue.isEmpty
                              ? (playing == null
                                  ? 'Lade ein Lied hoch, um etwas zu hören.'
                                  : 'Keine Songs in der Warteschlange.')
                              : 'Als nächstes: ${player.queue.first.title}'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              for (final icon in [Icons.shuffle, Icons.skip_previous, Icons.play_arrow, Icons.skip_next, Icons.repeat])
                Icon(icon, color: scheme.onSurfaceVariant),
            ],
          ),
        );
      },
    );
  }
}
