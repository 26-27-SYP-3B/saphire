import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../features/library/data/local_library.dart';
import '../../features/playlists/domain/playlist.dart';
import 'track_art.dart';

/// The desktop sidebar below the navigation: "Deine Bibliothek" with the filter chips Spotify
/// puts there, and the playlists the caller owns (plus the ones stored on this device).
///
/// The page that already read the playlists hands them in, so opening a page does not send a
/// second request for the same list. A page that has none (the start page) shows only the
/// device playlists and the chips.
class LibrarySidebar extends StatelessWidget {
  const LibrarySidebar({
    super.key,
    this.playlists = const [],
    required this.localLibrary,
    required this.localMode,
  });

  final List<Playlist> playlists;
  final LocalLibrary localLibrary;
  final bool localMode;

  void _go(BuildContext context, String location) => context.go(location);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget chip(String label, String? to) => Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: InkWell(
        onTap: to == null ? null : () => _go(context, to),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: fieldBackground,
            border: Border.all(color: hairline),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label, style: theme.textTheme.labelSmall),
        ),
      ),
    );

    final localPlaylists = localMode ? localLibrary.playlists : const [];
    final rows = <Widget>[
      for (final playlist in playlists)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          leading: const TrackArt(size: 38, icon: Icons.queue_music),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('Playlist · ${playlist.songCount} Songs'),
          onTap: () => _go(context, '/playlists?id=${playlist.id}'),
        ),
      for (final playlist in localPlaylists)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10),
          leading: const TrackArt(size: 38, icon: Icons.queue_music),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('Lokal · ${playlist.songs.length} Songs'),
          onTap: () => _go(
            context,
            '/playlists?local=${Uri.encodeComponent(playlist.name)}',
          ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.library_books, size: 22, color: mutedText),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Deine Bibliothek',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Playlist erstellen',
                visualDensity: VisualDensity.compact,
                onPressed: () => _go(context, '/playlists?create=1'),
                icon: const Icon(Icons.add, color: mutedText),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            children: [
              chip('Playlists', '/playlists'),
              chip('Alben', '/library?view=albums'),
              chip('Künstler*innen', '/library?view=artists'),
              chip('Lokal', '/library?view=local'),
            ],
          ),
          const SizedBox(height: 6),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                'Noch keine Playlists.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ...rows,
        ],
      ),
    );
  }
}
