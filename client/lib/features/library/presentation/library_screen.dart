import 'package:flutter/material.dart';

import '../../../shared/widgets/saphire_sidebar.dart';
import '../../player/domain/player.dart';
import '../../player/presentation/player_bar.dart';
import '../data/library_repository.dart';
import '../domain/library_entry.dart';

/// The library: what GET /api/music answers, and the place where a song becomes a stream.
///
/// A row carries only what the answer carries — the title and the way to play it. Nothing
/// here is invented: no length, no bitrate, no cover, because the API has none.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({required this.library, required this.player, super.key});

  final LibraryRepository library;
  final Player player;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<LibraryEntry> _entries = [];
  String? _note;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _note = null;
    });

    try {
      final entries = await widget.library.list();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } on LibraryException catch (error) {
      // The page shows the server's own words, so a 429 says when the next try makes
      // sense and a broken library says which file is missing.
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 760;

      return Scaffold(
        backgroundColor: scheme.surface,
        body: SafeArea(
          child: Row(
            children: [
              if (wide) SaphireSidebar(selected: '/library', height: constraints.maxHeight),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Bibliothek', style: theme.textTheme.displaySmall),
                            const SizedBox(height: 6),
                            Text(
                              'Was jemand hochgeladen hat, kann jede Person hören.',
                              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                            const SizedBox(height: 20),
                            if (_loading) Text('Bibliothek wird gelesen.'),
                            if (_note != null) Text(_note!, style: TextStyle(color: scheme.error)),
                            if (!_loading && _note == null) ...[
                              if (_entries.isEmpty)
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Noch keine Lieder.', style: theme.textTheme.titleMedium),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Auf der Startseite kannst du ein Lied hochladen, dann erscheint es hier.',
                                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                                    ),
                                  ],
                                )
                              else ...[
                                Text('${_entries.length} Lieder', style: theme.textTheme.titleMedium),
                                const SizedBox(height: 10),
                                StreamBuilder<Playback>(
                                  stream: widget.player.playback,
                                  initialData: widget.player.current,
                                  builder: (context, snapshot) {
                                    final current = snapshot.data ?? widget.player.current;
                                    return Column(
                                      children: [
                                        // The marker shows what is playing, not what was opened last:
                                        // a song that is paused is not playing.
                                        for (final entry in _entries)
                                          _row(context, entry, current.playing && entry.id == current.song?.id),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                    PlayerBar(player: widget.player),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _row(BuildContext context, LibraryEntry entry, bool playing) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      // Tapping a row is what starts the stream for that song.
      onTap: () => widget.player.playSong(entry),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Icon(
              playing ? Icons.play_circle : Icons.play_circle_outline,
              size: 20,
              color: playing ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                entry.title,
                style: theme.textTheme.labelLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
