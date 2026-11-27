import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/player/domain/player.dart';
import 'track_art.dart';

/// The top of the desktop right column: the cover, the title and the artist of the song that
/// is playing, the way Spotify's "Now playing" view starts. The queue follows below it, so the
/// whole column says the same thing as the player bar.
class NowPlayingHeader extends StatefulWidget {
  const NowPlayingHeader({super.key, required this.player});

  final QueuePlayer player;

  @override
  State<NowPlayingHeader> createState() => _NowPlayingHeaderState();
}

class _NowPlayingHeaderState extends State<NowPlayingHeader> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = widget.player.localCurrent;
    final entry = widget.player.queue.current;
    final title = local?.title ?? entry?.title;
    final cover = local?.cover ?? entry?.cover;
    final artist = widget.player.statusNote;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Gerade läuft', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TrackArt(
                cover: cover,
                size: 96,
                radius: 8,
                icon: Icons.music_note,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title ?? 'Nichts wird abgespielt',
                      style: theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      artist,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
