import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../library/data/local_library.dart';
import '../../library/domain/local_playlist.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/queue.dart';
import '../data/playlist_repository.dart';
import '../domain/playlist.dart';

/// Playlists: create one, put songs in it, start it.
///
/// Starting a playlist does not play anything by itself. It fills the queue from that
/// playlist, and the player only ever reads a queue — so a queue filled from a playlist
/// and a queue filled from anything else behave the same. That is why this page hands
/// the work to the queue instead of playing songs itself.
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({
    super.key,
    required this.playlists,
    required this.queue,
    required this.queues,
    required this.session,
    this.settings,
    this.localLibrary,
  });

  final PlaylistRepository playlists;
  final QueueRepository queues;
  final PlaybackQueue queue;
  final SessionStore session;

  /// Null in a test that does not care about local mode: the stores then stay in memory.
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _trackId = TextEditingController();

  List<Playlist> _playlists = [];
  PlaylistWithSongs? _selected;
  LocalPlaylist? _selectedLocal;
  int _localTrack = -1;
  String? _note;
  bool _busy = false;

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _trackId.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Local mode has no server to ask. What is on the device is the whole list.
    if (_settings.localMode) {
      setState(() {
        _note = _local.playlists.isEmpty
            ? 'Noch keine Playlist. Eine Playlist gehört dir, nicht der geteilten Bibliothek.'
            : null;
      });
      return;
    }

    setState(() => _busy = true);
    try {
      final playlists = await widget.playlists.list();
      if (!mounted) return;
      setState(() {
        _playlists = playlists;
        _note = playlists.isEmpty ? 'Noch keine Playlist. Eine Playlist gehört dir, nicht der geteilten Bibliothek.' : null;
        _busy = false;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      // Only a 401 says this token is gone; a 429 or a 400 is not a lost login. When the
      // app does drop it, the guard and the page agree on the same session.
      if (error.statusCode == 401) widget.session.clear();
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _create() async {
    if (_settings.localMode) {
      final created = _local.createPlaylist(_name.text);
      setState(() {
        if (created != null) _selectedLocal = created;
        _note = created == null
            ? 'Bitte einen Namen eingeben, der noch nicht vergeben ist.'
            : 'Playlist „${created.name}“ angelegt.';
      });
      return;
    }

    setState(() => _busy = true);
    try {
      final created = await widget.playlists.create(_name.text);
      if (!mounted) return;
      // The action keeps its name: what the button says is what happened.
      setState(() {
        _playlists = [..._playlists, created];
        _selected = PlaylistWithSongs(playlist: created, songs: []);
        _note = 'Playlist „${created.name}“ angelegt.';
        _busy = false;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  // The list on the left shows how many songs a playlist has. Adding or removing one here
  // changes that number, so the stored playlist is updated with the rows the user is
  // looking at — otherwise the sidebar keeps an old count while the detail pane is correct.
  void _countChanged(int playlistId, int count) {
    for (var i = 0; i < _playlists.length; i++) {
      if (_playlists[i].id == playlistId) {
        _playlists[i] = Playlist(
          id: _playlists[i].id,
          name: _playlists[i].name,
          createdAt: _playlists[i].createdAt,
          songCount: count,
        );
        return;
      }
    }
  }

  Future<void> _open(Playlist playlist) async {
    setState(() => _busy = true);
    try {
      final detail = await widget.playlists.get(playlist.id);
      if (!mounted) return;
      setState(() {
        _selected = detail;
        _note = null;
        _busy = false;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _openLocal(LocalPlaylist playlist) async {
    setState(() {
      _selectedLocal = playlist;
      _localTrack = -1;
      _note = null;
    });
  }

  Future<void> _addSong() async {
    if (_settings.localMode) {
      final playlist = _selectedLocal;
      if (playlist == null) return;

      if (_localTrack < 0 || _localTrack >= _local.tracks.length) {
        setState(() => _note = 'Bitte ein Lied aus der lokalen Bibliothek wählen.');
        return;
      }

      _local.addToPlaylist(playlist, _local.tracks[_localTrack]);
      setState(() {
        _note = 'Song an Position ${playlist.songs.length} eingefügt.';
        _localTrack = -1;
      });
      return;
    }

    final detail = _selected;
    if (detail == null) return;

    // The number is sent as typed. When it is not a number the page says so itself
    // instead of sending something it did not get from the user — an invented -1 would
    // make the server answer about a value nobody typed.
    final text = _trackId.text.trim();
    final trackId = int.tryParse(text);
    if (trackId == null) {
      setState(() => _note = 'Bitte die Lied-Nummer als Zahl eingeben, zum Beispiel 4.');
      return;
    }

    setState(() => _busy = true);
    try {
      final song = await widget.playlists.addSong(detail.playlist.id, trackId);
      if (!mounted) return;
      // The position the server answered with is the one the row shows.
      setState(() {
        _selected = PlaylistWithSongs(playlist: detail.playlist, songs: [...detail.songs, song]);
        _note = 'Song an Position ${song.position} eingefügt.';
        _busy = false;
        // The list on the left shows a count; it has to say the same as the rows here.
        _countChanged(detail.playlist.id, detail.songs.length + 1);
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _removeSong(int position) async {
    if (_settings.localMode) {
      final playlist = _selectedLocal;
      if (playlist == null || position < 1 || position > playlist.songs.length) return;

      setState(() {
        _local.removeFromPlaylist(playlist, position - 1);
        _note = 'Position $position entfernt.';
      });
      return;
    }

    final detail = _selected;
    if (detail == null) return;

    setState(() => _busy = true);
    try {
      await widget.playlists.removeSong(detail.playlist.id, position);
      if (!mounted) return;

      // The server renumbers the songs after the removed one, so the rows shift up. The
      // positions the page shows afterwards are the ones the next read would return.
      final remaining = [
        for (final song in detail.songs)
          if (song.position != position)
            song.position > position
                ? PlaylistSong(position: song.position - 1, trackId: song.trackId, title: song.title)
                : song,
      ];

      setState(() {
        _selected = PlaylistWithSongs(playlist: detail.playlist, songs: remaining);
        _countChanged(detail.playlist.id, remaining.length);
        _note = 'Position $position entfernt.';
        _busy = false;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _start() async {
    if (_settings.localMode) {
      final playlist = _selectedLocal;
      if (playlist == null) return;
      if (playlist.songs.isEmpty) {
        setState(() => _note = 'Diese Playlist hat noch keine Lieder.');
        return;
      }

      // The stored queue is what the queue page plays, so it works again after a restart.
      _local.setQueue(playlist.songs);
      setState(() => _note = null);
      context.push('/queue');
      return;
    }

    final detail = _selected;
    if (detail == null) return;

    setState(() => _busy = true);
    try {
      // Starting a playlist means filling the queue from it. The queue does not know it
      // came from a playlist.
      final entries = await widget.queues.fill(QueueSource.playlist(detail.playlist.id));
      if (!mounted) return;
      widget.queue.fill(entries);

      // The page stays alive in the navigation stack, so the flag has to be released
      // before leaving: coming back here would otherwise leave every button disabled.
      setState(() => _busy = false);
      context.push('/queue');
    } on QueueException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Playlists', style: theme.textTheme.displaySmall),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Name der Playlist'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(onPressed: _busy ? null : _create, child: const Text('Anlegen')),
                  ],
                ),
                if (_note != null) ...[
                  const SizedBox(height: 12),
                  Text(_note!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
                ],
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                SizedBox(width: 300, child: _list()),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 20, 20),
                    child: _detail(theme),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    // Local mode lists what is on the device. The rows look the same as the server's,
    // because a playlist is a name and songs either way.
    if (_settings.localMode) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        itemCount: _local.playlists.length,
        itemBuilder: (context, index) {
          final playlist = _local.playlists[index];

          return ListTile(
            title: Text(playlist.name),
            subtitle: Text('${playlist.songs.length} Songs'),
            selected: identical(_selectedLocal, playlist),
            onTap: _busy ? null : () => _openLocal(playlist),
          );
        },
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        final selected = _selected?.playlist.id == playlist.id;

        return ListTile(
          title: Text(playlist.name),
          subtitle: Text('${playlist.songCount} Songs'),
          selected: selected,
          onTap: _busy ? null : () => _open(playlist),
        );
      },
    );
  }

  Widget _detail(ThemeData theme) {
    if (_settings.localMode) return _localDetail(theme);

    if (_selected == null) {
      return Text('Eine Playlist auswählen, um ihre Songs zu sehen.', style: theme.textTheme.bodyMedium);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(_selected!.playlist.name, style: theme.textTheme.titleMedium)),
            FilledButton(
              onPressed: _busy ? null : _start,
              child: const Text('Playlist starten'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _trackId,
                keyboardType: TextInputType.number,
                // The value is sent as typed: a negative id is what
                // makes the server answer with its own message.
                decoration: const InputDecoration(labelText: 'Track id aus der Bibliothek'),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(onPressed: _busy ? null : _addSong, child: const Text('Hinzufügen')),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            itemCount: _selected!.songs.length,
            itemBuilder: (context, index) {
              final song = _selected!.songs[index];
              return ListTile(
                leading: Text('${song.position}'),
                title: Text(song.title),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => _removeSong(song.position),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _localDetail(ThemeData theme) {
    final playlist = _selectedLocal;
    if (playlist == null) {
      return Text('Eine Playlist auswählen, um ihre Songs zu sehen.', style: theme.textTheme.bodyMedium);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(playlist.name, style: theme.textTheme.titleMedium)),
            FilledButton(
              onPressed: _busy ? null : _start,
              child: const Text('Playlist starten'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: _localTrack >= 0 && _localTrack < _local.tracks.length ? _localTrack : null,
                hint: const Text('Lied aus der lokalen Bibliothek wählen'),
                items: [
                  for (var i = 0; i < _local.tracks.length; i++)
                    DropdownMenuItem(value: i, child: Text(_local.tracks[i].title)),
                ],
                onChanged: _busy ? null : (value) => setState(() => _localTrack = value ?? -1),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(onPressed: _busy ? null : _addSong, child: const Text('Hinzufügen')),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            itemCount: playlist.songs.length,
            itemBuilder: (context, index) {
              final song = playlist.songs[index];
              return ListTile(
                leading: Text('${index + 1}'),
                title: Text(song.title),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => _removeSong(index + 1),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
