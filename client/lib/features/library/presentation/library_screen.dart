import 'package:flutter/material.dart';

import '../../../core/utils/pick_audio.dart';
import '../../../shared/widgets/nav_bar.dart';
import '../../../shared/widgets/player_bar.dart';
import '../../player/data/player.dart';
import '../../playlists/data/playlist_store.dart';
import '../../upload/data/upload_repository.dart';
import '../../upload/domain/track.dart';
import '../data/library_repository.dart';

/// The three the list can be ordered by. There is nothing else to order by.
const sortKeys = ['Titel', 'Interpret', 'Hinzugefügt am'];

/// The artist shown for a row: what the file's tags name (api-docs.md, the artist
/// field). Only a title that is still the name the client sent can be read as
/// "interpret - titel", because that pattern is a naming habit, not something a tag
/// says. A title that came from a tag is not a name, so nothing is guessed from it
/// and the row shows a dash.
String artistOf(Track track) => track.artist.isNotEmpty
    ? track.artist
    : (looksLikeFileName(track.title) ? artistFromName(track.title) : '');

/// The extensions the server accepts (see api-docs.md), so a title ending in one of
/// them is the name it was stored under rather than a tagged title.
const fileExtensions = ['mp3', 'wav', 'm4a', 'ogg', 'opus', 'flac', 'aac'];

bool looksLikeFileName(String title) {
  final dot = title.lastIndexOf('.');
  return dot > 0 && fileExtensions.contains(title.substring(dot + 1).toLowerCase());
}

/// The naming habit of an untagged file: "interpret - titel.mp3".
String artistFromName(String title) {
  final split = title.indexOf(' - ');
  return split < 1 ? '' : title.substring(0, split);
}

/// A row shows the length as mm:ss. A file the server could not measure shows a
/// dash, which is honest rather than a guessed number.
const unknownDuration = '–';
String durationOf(Track track) {
  if (track.durationMs <= 0) return unknownDuration;

  final seconds = track.durationMs ~/ 1000;
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

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

  // Reading the list and sending a batch are two different things. One flag for both
  // would make the button say "Wird hochgeladen…" while nothing is being uploaded, and
  // a batch could be sent into a list that is still on its way.
  bool _loading = false;
  bool _uploading = false;

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
    setState(() => _loading = true);

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
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _upload() async {
    // The button stays disabled for the whole batch, so a second click cannot send the
    // same files again. A picker that fails must release it too.
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final picked = await widget.pickAudio();
      if (picked == null) return;

      for (final file in picked) {
        try {
          // The server answers with the row it stored, so the song is in the library
          // here without reading the list again.
          final track = await widget.uploads.upload(filename: file.name, bytes: file.bytes);
          if (!mounted) return;
          setState(() => _tracks.add(track));
        } on UploadException catch (error) {
          // A file the server refused is not added. In a batch the message has to say
          // which file it is about, and a later success must not hide it.
          if (mounted) setState(() => _note = '${file.name}: ${error.message}');
        }
      }
    } catch (error) {
      // The picker itself failing is not a file the server refused, so the row above
      // cannot name a file. The message says what the user can do next.
      if (mounted) setState(() => _note = 'Die Dateien konnten nicht gelesen werden. Versuch es erneut.');
    } finally {
      if (mounted) setState(() => _uploading = false);
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
            artistOf(track).toLowerCase().contains(query))
          track,
    ];

    // Names and artists are compared without case, so "ahne" comes before "Zehn" the
    // way a user reads it. What is not available is a dictionary collation, so an umlaut
    // still sorts by its code point, after z.
    //
    // Newest first for the date; the id decides what the date cannot, so the order does
    // not change on every rebuild.
    switch (_sort) {
      case 'Interpret':
        rows.sort((a, b) {
          final byArtist = artistOf(a).toLowerCase().compareTo(artistOf(b).toLowerCase());
          return byArtist != 0 ? byArtist : a.id.compareTo(b.id);
        });
      case 'Hinzugefügt am':
        rows.sort((a, b) => b.uploadedAt != a.uploadedAt
            ? b.uploadedAt.compareTo(a.uploadedAt)
            : b.id.compareTo(a.id));
      default:
        rows.sort((a, b) {
          final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
        });
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
            // The same navigation as the home page, drawn as the row this page has room
            // for: it marks which screen this is and lets the user go back. A heading
            // would only repeat what the marked item already says.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 24, 8),
              child: NavBar(selected: '/library', vertical: false),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
              child: Row(
                children: [
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
                  // library is empty or already has songs in it. Its label follows what
                  // is actually happening, and it is not usable while a batch is on its
                  // way or while the list it would add to is still being read.
                  FilledButton(
                    onPressed: _loading || _uploading ? null : _upload,
                    child: Text(_uploading ? 'Wird hochgeladen…' : 'Song hochladen'),
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
          // The upload button is in the row above. Where a message above already says
          // what went wrong, nothing here claims what the library holds.
          if (_note == null)
            Text(
              _tracks.isEmpty
                  ? 'Die Bibliothek ist noch leer. Lade einen Song hoch, um sie zu füllen.'
                  : 'Keine Songs passen zur Suche.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  /// One song: its name, what the file says about it, and the actions the menu has.
  /// The whole row can be tapped, so playing a song does not need the small icon.
  Widget _row(Track track) {
    final theme = Theme.of(context);
    final artist = artistOf(track);

    return InkWell(
      onTap: () => widget.player.play(track),
      child: Container(
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
                    // What is known about the song: the artist its tags name, or what
                    // its own says when they do not, and the length the server worked
                    // out. Where nothing is known, the row shows a dash.
                    '${artist.isEmpty ? '–' : artist} · ${durationOf(track)}',
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
      ),
    );
  }
}
