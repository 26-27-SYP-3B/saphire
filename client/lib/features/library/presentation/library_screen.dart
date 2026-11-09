import 'package:flutter/material.dart';

import '../../../core/utils/pick_audio.dart';
import '../../../shared/widgets/player_bar.dart';
import '../../player/data/player.dart';
import '../../playlists/data/playlist_store.dart';
import '../../upload/data/upload_repository.dart';
import '../../upload/domain/track.dart';
import '../data/library_repository.dart';

/// The three the list can be ordered by. These are all the client can do: the
/// answer carries a title and the order the server sent it in, nothing else.
const sortKeys = ['Titel', 'Interpret', 'Hinzugefügt am'];

/// The artist is only what the name itself says, "interpret - titel.mp3", because
/// the library answer has no artist field (see api-docs.md, GET /api/music).
/// shortcut: nothing more is known about a song. Upgrade: the server sends artist
/// and duration, then this reads them instead of the name.
String artistOf(String title) {
  final split = title.indexOf(' - ');
  return split < 2 ? '' : title.substring(0, split);
}

/// A duration is not in the answer at all, so a row shows what is known: nothing.
const unknownDuration = '–';

/// The library screen: the songs the server has, filtered and sorted, with the
/// same actions the rest of the app uses — play, add to a playlist, add to the
/// queue, upload a new song.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.player,
    required this.playlists,
    required this.uploads,
    this.pickAudio = pickAudioFiles,
  });

  final LibraryRepository library;
  final Player player;
  final PlaylistStore playlists;
  final UploadRepository uploads;
  final PickAudio pickAudio;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _search = TextEditingController();

  String _sort = sortKeys.first;
  List<Track> _tracks = [];

  // What a request answered: an error, or nothing when all is well.
  String? _note;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _busy = true);

    try {
      final tracks = await widget.library.list();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _note = null;
      });
    } on LibraryException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    if (_busy) return;
    setState(() => _busy = true);

    final picked = await widget.pickAudio();
    if (!mounted) return;
    setState(() => _busy = false);
    if (picked == null) return;

    for (final file in picked) {
      try {
        // The server answers with the row it stored, so the song is in the library
        // here without reading the list again.
        final track = await widget.uploads.upload(filename: file.name, bytes: file.bytes);
        if (!mounted) return;
        setState(() {
          _tracks.add(track);
          _note = null;
        });
      } on UploadException catch (error) {
        // A file the server refused is not added; only its message is shown.
        if (mounted) setState(() => _note = error.message);
      }
    }
  }

  /// What the page shows now: the rows that match the search, in the order the
  /// dropdown asks for.
  List<Track> _visible() {
    final query = _search.text.trim().toLowerCase();
    final rows = [
      for (final track in _tracks)
        if (query.isEmpty ||
            track.title.toLowerCase().contains(query) ||
            artistOf(track.title).toLowerCase().contains(query))
          track,
    ];

    // Newest first for "Hinzugefügt am"; when the answer has no date the id is the
    // order the server already sent, so the sort does nothing.
    switch (_sort) {
      case 'Interpret':
        rows.sort((a, b) => artistOf(a.title).compareTo(artistOf(b.title)));
      case 'Hinzugefügt am':
        rows.sort((a, b) => b.uploadedAt != a.uploadedAt
            ? b.uploadedAt.compareTo(a.uploadedAt)
            : b.id.compareTo(a.id));
      default:
        rows.sort((a, b) => a.title.compareTo(b.title));
    }

    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _visible();

    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Row(
                children: [
                  Text('Bibliothek', style: theme.textTheme.titleLarge),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(hintText: 'Songs suchen'),
                    ),
                  ),
                  const SizedBox(width: 16),
                  DropdownButton<String>(
                    value: _sort,
                    items: [
                      for (final key in sortKeys)
                        DropdownMenuItem(value: key, child: Text('Sortieren: $key')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _sort = value);
                    },
                  ),
                  const SizedBox(width: 16),
                  // One button for the whole page, so uploading works whether the
                  // library is empty or already has songs in it.
                  FilledButton(
                    onPressed: _busy ? null : _upload,
                    child: Text(_busy ? 'Wird hochgeladen…' : 'Song hochladen'),
                  ),
                ],
              ),
            ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Text(_note!, style: TextStyle(color: scheme.error)),
              ),
            Expanded(
              child: rows.isEmpty
                  ? _empty()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                      itemCount: rows.length,
                      itemBuilder: (context, index) => _row(rows[index]),
                    ),
            ),
            PlayerBar(player: widget.player),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // The upload button is in the row above, so this only says what is
            // missing and why the page is empty.
            _tracks.isEmpty
                ? 'Deine Bibliothek ist noch leer. Lade einen Song hoch, um sie zu füllen.'
                : 'Keine Songs passen zur Suche.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _row(Track track) {
    final theme = Theme.of(context);
    final artist = artistOf(track.title);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: theme.colorScheme.outline))),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Abspielen',
            onPressed: () => widget.player.play(track),
            icon: const Icon(Icons.play_arrow),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title, style: theme.textTheme.labelLarge),
                Text(
                  // What is known about the song: the artist from its name and the
                  // time it was added. Where nothing is known, the row shows a dash.
                  '${artist.isEmpty ? '–' : artist} · $unknownDuration',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Aktionen für ${track.title}',
            onSelected: (value) {
              if (value == 'queue') {
                widget.player.addToQueue(track);
              } else {
                widget.playlists.add(value.substring('playlist:'.length), track.id);
              }
            },
            itemBuilder: (context) => [
              // Which playlists exist is the playlist feature's own screen; here the
              // menu can only add to one that is there, or start a new one.
              if (widget.playlists.names.isEmpty)
                const PopupMenuItem(value: 'playlist:Meine Playlist', child: Text('Zur neuen Playlist „Meine Playlist“')),
              for (final name in widget.playlists.names)
                PopupMenuItem(value: 'playlist:$name', child: Text('Zur Playlist „$name“')),
              const PopupMenuItem(value: 'queue', child: Text('Zur Warteschlange hinzufügen')),
            ],
          ),
        ],
      ),
    );
  }
}
