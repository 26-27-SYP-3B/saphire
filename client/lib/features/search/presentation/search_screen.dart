import 'dart:async';

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../../shared/domain/track.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/track_art.dart';
import '../../library/data/library_repository.dart';
import '../../library/data/local_library.dart';
import '../../library/domain/local_track.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/player.dart';
import '../../player/domain/queue.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../playlists/domain/playlist.dart';

/// The search page: the same field the start page has, but it searches both the server library
/// and the songs on this device, so one answer is one list of playable rows.
///
/// There is no search endpoint (api-docs.md, Upcoming), so this reads the library once and
/// filters what it got. A page that searches a library that changes under it would need the
/// endpoint; until then the shortcut is the same one the library page uses.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.library,
    required this.playlists,
    required this.queues,
    required this.queue,
    required this.player,
    required this.session,
    this.settings,
    this.localLibrary,
  });

  final LibraryRepository library;
  final PlaylistRepository playlists;
  final QueueRepository queues;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _search = TextEditingController();

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  List<Track> _server = [];
  List<Playlist> _playlists = [];
  String? _note;
  bool _busy = false;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    if (!_settings.localMode) _load();
  }

  @override
  void dispose() {
    _changes?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tracks = await widget.library.list();
      if (mounted) setState(() => _server = tracks);
    } on LibraryException catch (error) {
      if (mounted) setState(() => _note = error.message);
    }
    try {
      final playlists = await widget.playlists.list();
      if (mounted) setState(() => _playlists = playlists);
    } on PlaylistException {
      // The menus fall back to "no playlist"; the songs are what this page is for.
    }
  }

  List<Track> get _all => [
    ..._server,
    for (final track in _local.tracks) track.toTrack(),
  ];

  List<Track> _results() {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return [
      for (final track in _all)
        if (track.title.toLowerCase().contains(query) ||
            track.artist.toLowerCase().contains(query) ||
            track.album.toLowerCase().contains(query))
          track,
    ];
  }

  Future<void> _play(Track track) => _control(() async {
    if (track.isLocal) {
      await widget.player.playLocal(track.toLocalTrack());
      return;
    }
    widget.queue.fill(await widget.queues.fill(QueueSource.track(track.id)));
    await widget.player.playCurrent();
  });

  Future<void> _addToQueue(Track track) => _control(() async {
    if (track.isLocal) {
      _local.addToQueue(track.toLocalTrack());
      await widget.player.syncLocalQueue(_local.queue);
      if (mounted) {
        setState(() => _note = '${track.title} in die Warteschlange gelegt.');
      }
      return;
    }
    final entry = await widget.queues.append(track.id);
    if (mounted) {
      widget.queue.append(entry.asManual());
      setState(() => _note = '${track.title} in die Warteschlange gelegt.');
    }
  });

  Future<void> _addToPlaylist(
    Track track,
    int? playlistId,
    String? localName,
  ) async {
    await _control(() async {
      if (track.isLocal) {
        final match = _local.playlists.where(
          (playlist) => playlist.name == localName,
        );
        if (match.isEmpty) return;
        _local.addToPlaylist(match.first, track.toLocalTrack());
        if (mounted) {
          setState(
            () =>
                _note = 'Song zur Playlist „${match.first.name}“ hinzugefügt.',
          );
        }
        return;
      }

      int id = playlistId ?? 0;
      if (id == 0) {
        final created = await widget.playlists.create('Meine Playlist');
        if (!mounted) return;
        setState(() => _playlists = [..._playlists, created]);
        id = created.id;
      }
      final song = await widget.playlists.addSong(id, track.id);
      if (mounted) {
        setState(
          () => _note =
              'Song an Position ${song.position} zur Playlist hinzugefügt.',
        );
      }
    });
  }

  Future<void> _control(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await action();
    } on QueueException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } on PlaylistException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } catch (error) {
      if (mounted) {
        setState(() => _note = 'Das Lied konnte nicht gespielt werden: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final results = _results();
    final query = _search.text.trim();

    return AppShell(
      selected: '/search',
      player: widget.player,
      queues: widget.queues,
      playlists: widget.playlists,
      library: widget.library,
      session: widget.session,
      localMode: _settings.localMode,
      localLibrary: _local,
      sidebarPlaylists: _playlists,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Text('Suche', style: theme.textTheme.displaySmall),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Wonach suchst du?',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(_note!, style: TextStyle(color: scheme.error)),
            ),
          Expanded(
            child: query.isEmpty
                ? _start(theme)
                : results.isEmpty
                ? _empty(theme)
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 24, 24),
                    itemCount: results.length,
                    itemBuilder: (context, index) => _row(results[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _start(ThemeData theme) {
    final hint = _settings.localMode
        ? 'Durchsuche die Songs auf diesem Gerät.'
        : 'Durchsuche die Bibliothek und deine lokalen Songs.';

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          hint,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(color: mutedText),
        ),
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    return Center(
      child: Text(
        'Keine Songs gefunden.',
        style: theme.textTheme.bodyMedium?.copyWith(color: mutedText),
      ),
    );
  }

  Widget _row(Track track) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = track.isLocal
        ? identical(widget.player.localCurrent?.path, track.localPath)
        : widget.queue.current?.trackId == track.id;

    return InkWell(
      onTap: _busy ? null : () => _play(track),
      onSecondaryTapDown: (details) =>
          _contextMenu(details.globalPosition, track),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            TrackArt(cover: track.cover, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: current ? scheme.primary : scheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    track.artist.isEmpty
                        ? (track.isLocal ? 'Lokal' : '–')
                        : track.artist,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (track.isLocal) const SourceBadge(local: true),
            const SizedBox(width: 8),
            PopupMenuButton<String>(
              tooltip: 'Aktionen für ${track.title}',
              onSelected: (value) {
                if (value == 'queue') {
                  _addToQueue(track);
                } else if (value == 'new') {
                  _addToPlaylist(track, null, null);
                } else if (value.startsWith('local:')) {
                  _addToPlaylist(track, null, value.substring(6));
                } else {
                  _addToPlaylist(track, int.tryParse(value), null);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'queue',
                  child: Text('Zur Warteschlange hinzufügen'),
                ),
                if (track.isLocal) ...[
                  if (_local.playlists.isEmpty)
                    const PopupMenuItem(
                      enabled: false,
                      child: Text('Keine lokale Playlist'),
                    )
                  else
                    for (final playlist in _local.playlists)
                      PopupMenuItem(
                        value: 'local:${playlist.name}',
                        child: Text('Zu „${playlist.name}“'),
                      ),
                ] else ...[
                  if (_playlists.isEmpty)
                    const PopupMenuItem(
                      value: 'new',
                      child: Text('Zur neuen Playlist „Meine Playlist“'),
                    )
                  else
                    for (final playlist in _playlists)
                      PopupMenuItem(
                        value: '${playlist.id}',
                        child: Text('Zu „${playlist.name}“'),
                      ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _contextMenu(Offset position, Track track) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(
          value: 'queue',
          child: Text('Zur Warteschlange hinzufügen'),
        ),
      ],
    );
    if (value == 'queue') await _addToQueue(track);
  }
}
