import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../../core/utils/pick_image.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../library/data/library_repository.dart';
import '../../library/data/local_library.dart';
import '../../library/domain/local_playlist.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/player.dart';
import '../../player/domain/queue.dart';
import '../../upload/domain/track.dart';
import '../data/cover_store.dart';
import '../data/playlist_repository.dart';
import '../domain/playlist.dart';

const _emptyNote = 'Noch keine Playlist. Eine Playlist gehört dir, nicht der geteilten Bibliothek.';

/// Playlists: create one with a title and a cover, put songs in it, start it.
///
/// Starting a playlist fills the queue from that playlist and plays its first song. The
/// player only ever reads a queue — so a queue filled from a playlist and a queue filled
/// from anything else behave the same. That is why this page hands the work to the queue
/// instead of playing songs itself; the queue itself lives in the bar at the bottom.
///
/// The cover is picked on this device and stays here: the server keeps a playlist as a
/// name and song positions (api-docs.md), so there is no image to upload.
class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({
    super.key,
    required this.playlists,
    required this.library,
    required this.queue,
    required this.queues,
    required this.session,
    required this.player,
    this.pickImage = pickImageFile,
    this.settings,
    this.localLibrary,
    this.covers,
  });

  final PlaylistRepository playlists;
  final LibraryRepository library;
  final QueueRepository queues;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;

  /// What a cover is picked with. A widget test passes its own, because the plugin cannot
  /// answer there.
  final PickImage pickImage;

  /// Null in a test that does not care about local mode: the stores then stay in memory.
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;
  final CoverStore? covers;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  final TextEditingController _name = TextEditingController();

  List<Playlist> _playlists = [];
  List<Track> _library = [];
  PlaylistWithSongs? _selected;
  LocalPlaylist? _selectedLocal;

  /// The image picked for the playlist that is about to be created. It gets its place in
  /// the cover store only once the create answered with an id or a name.
  Uint8List? _newCover;

  /// Which song of the picker is chosen, or -1 for none. One number for both modes,
  /// because it only names a row in the list the page shows.
  int _song = -1;
  String? _note;
  bool _busy = false;

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();
  late final CoverStore _covers = widget.covers ?? CoverStore();

  bool get _isLocal => _settings.localMode;

  /// The songs a playlist can be filled from: the shared library on the server, the songs
  /// on the device without one.
  List<String> get _songTitles => _isLocal
      ? [for (final track in _local.tracks) track.title]
      : [for (final track in _library) track.title];

  String? get _selectedName => _isLocal ? _selectedLocal?.name : _selected?.playlist.name;

  /// The rows of the open playlist. A local playlist numbers its songs by their place, a
  /// server playlist by the position the server gave them; both are 1-based and contiguous.
  List<({int position, String title})> get _selectedSongs {
    if (_isLocal) {
      final playlist = _selectedLocal;
      if (playlist == null) return const [];
      return [
        for (var i = 0; i < playlist.songs.length; i++) (position: i + 1, title: playlist.songs[i].title),
      ];
    }
    final songs = _selected?.songs ?? const <PlaylistSong>[];
    return [for (final song in songs) (position: song.position, title: song.title)];
  }

  String? get _selectedCoverKey {
    if (_isLocal) {
      final name = _selectedLocal?.name;
      return name == null ? null : 'local:$name';
    }
    final id = _selected?.playlist.id;
    return id == null ? null : _serverKey(id);
  }

  /// A playlist id is unique inside one database only, and the app can be pointed at
  /// another server, so the address is part of the key.
  String _serverKey(int id) => 'server:$apiBaseUrl:$id';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Local mode has no server to ask. What is on the device is the whole list.
    if (_isLocal) {
      setState(() => _note = _local.playlists.isEmpty ? _emptyNote : null);
      return;
    }

    setState(() => _busy = true);
    try {
      final playlists = await widget.playlists.list();
      if (!mounted) return;
      setState(() {
        _playlists = playlists;
        _note = playlists.isEmpty ? _emptyNote : null;
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

    // The picker names songs the way the library does, so it needs the whole list once.
    // A failure here leaves the playlists visible and only the picker empty; it must not
    // overwrite what the page already said.
    try {
      final library = await widget.library.list();
      if (mounted) setState(() => _library = library);
    } on LibraryException catch (error) {
      if (mounted && _note == null) setState(() => _note = error.message);
    }
  }

  Future<void> _create() async {
    if (_isLocal) {
      final created = _local.createPlaylist(_name.text);
      if (created == null) {
        setState(() => _note = 'Bitte einen Titel eingeben, der noch nicht vergeben ist.');
        return;
      }

      final stored = await _takeCover('local:${created.name}');
      if (!mounted) return;
      setState(() {
        _selectedLocal = created;
        _note = stored
            ? 'Playlist „${created.name}“ angelegt.'
            : 'Playlist „${created.name}“ angelegt. Das Bild konnte nicht gespeichert werden.';
        _song = -1;
      });
      return;
    }

    setState(() => _busy = true);
    try {
      final created = await widget.playlists.create(_name.text);
      if (!mounted) return;
      final stored = await _takeCover(_serverKey(created.id));
      if (!mounted) return;
      // The action keeps its name: what the button says is what happened.
      setState(() {
        _playlists = [..._playlists, created];
        _selected = PlaylistWithSongs(playlist: created, songs: []);
        _note = stored
            ? 'Playlist „${created.name}“ angelegt.'
            : 'Playlist „${created.name}“ angelegt. Das Bild konnte nicht gespeichert werden.';
        _busy = false;
        _song = -1;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  /// The image picked before the create was for the playlist the create just made, and
  /// only now is there a key to keep it under. False says the storage refused it.
  Future<bool> _takeCover(String key) async {
    final cover = _newCover;
    if (cover == null) return true;
    final stored = await _covers.save(key, cover);
    _newCover = null;
    return stored;
  }

  /// A picked image is kept under `key`; the playlist that is still being created has no
  /// key yet, so its image waits in `_newCover` until the create answers.
  Future<void> _pickCover(String? key) async {
    final Uint8List? picked;
    try {
      picked = await widget.pickImage();
    } catch (_) {
      if (mounted) setState(() => _note = 'Das Bild konnte nicht gelesen werden.');
      return;
    }
    if (picked == null || !mounted) return;

    // Refused rather than cut, so the stored image is the one that was picked.
    if (picked.length > maxCoverBytes) {
      setState(() => _note = 'Das Bild ist größer als 1 MB. Bitte ein kleineres wählen.');
      return;
    }
    if (!isImage(picked)) {
      setState(() => _note = 'Die Datei ist kein Bild (PNG, JPEG, GIF oder WebP).');
      return;
    }

    if (key == null) {
      setState(() {
        _newCover = picked;
        _note = null;
      });
      return;
    }

    final stored = await _covers.save(key, picked);
    if (!mounted) return;
    setState(() => _note = stored
        ? null
        : 'Das Bild konnte nicht gespeichert werden. Es bleibt nur bis zum Neustart sichtbar.');
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
        _selectedLocal = null;
        _note = null;
        _busy = false;
        _song = -1;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  void _openLocal(LocalPlaylist playlist) {
    setState(() {
      _selectedLocal = playlist;
      _selected = null;
      _song = -1;
      _note = null;
    });
  }

  Future<void> _addSong() async {
    final index = _song;
    if (index < 0 || index >= _songTitles.length) {
      setState(() => _note = _isLocal
          ? 'Bitte ein Lied aus der lokalen Bibliothek wählen.'
          : 'Bitte ein Lied aus der Bibliothek wählen.');
      return;
    }

    if (_isLocal) {
      final playlist = _selectedLocal;
      if (playlist == null) return;

      _local.addToPlaylist(playlist, _local.tracks[index]);
      setState(() {
        _note = 'Song an Position ${playlist.songs.length} eingefügt.';
        _song = -1;
      });
      return;
    }

    final detail = _selected;
    if (detail == null) return;

    setState(() => _busy = true);
    try {
      final song = await widget.playlists.addSong(detail.playlist.id, _library[index].id);
      if (!mounted) return;
      // The position the server answered with is the one the row shows.
      setState(() {
        _selected = PlaylistWithSongs(playlist: detail.playlist, songs: [...detail.songs, song]);
        _note = 'Song an Position ${song.position} eingefügt.';
        _busy = false;
        _song = -1;
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
    if (_isLocal) {
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
    if (_isLocal) {
      final playlist = _selectedLocal;
      if (playlist == null) return;
      if (playlist.songs.isEmpty) {
        setState(() => _note = 'Diese Playlist hat noch keine Lieder.');
        return;
      }

      // The stored queue is what the bar plays, so it works again after a restart.
      _local.setQueue(playlist.songs);
      setState(() => _busy = true);
      try {
        // Starting a playlist fills the queue and plays its first song; the bar is where the
        // queue shows up now, so there is no page to open.
        await widget.player.playLocalQueue(playlist.songs);
        if (!mounted) return;
        setState(() {
          _note = null;
          _busy = false;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _note = switch (error) {
            PlaybackException(:final message) => message,
            _ => 'Die Playlist konnte nicht gestartet werden: $error',
          };
          _busy = false;
        });
      }
      return;
    }

    final detail = _selected;
    if (detail == null) return;
    if (detail.songs.isEmpty) {
      setState(() => _note = 'Diese Playlist hat noch keine Lieder.');
      return;
    }

    setState(() => _busy = true);
    try {
      // Starting a playlist means filling the queue from it. The queue does not know it
      // came from a playlist.
      final entries = await widget.queues.fill(QueueSource.playlist(detail.playlist.id));
      if (!mounted) return;
      widget.queue.fill(entries);

      // The first song is opened as well: the queue itself lives in the bar, so filling it
      // without playing would look like nothing happened.
      await widget.player.playCurrent();
      if (!mounted) return;
      setState(() => _note = null);
    } on QueueException catch (error) {
      if (!mounted) return;
      setState(() => _note = error.message);
    } catch (error) {
      // A song that cannot be opened is not a queue error, so it is reported like the local
      // branch does.
      if (!mounted) return;
      setState(() => _note = switch (error) {
        PlaybackException(:final message) => message,
        _ => 'Das Lied konnte nicht gespielt werden: $error',
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return AppShell(
      selected: '/playlists',
      player: widget.player,
      queues: widget.queues,
      library: widget.library,
      localMode: _isLocal,
      localLibrary: _local,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Playlists', style: theme.textTheme.displaySmall),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Cover(
                  cover: _newCover,
                  size: 56,
                  icon: Icons.add_photo_alternate_outlined,
                  onTap: _busy ? null : () => _pickCover(null),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Titel der Playlist'),
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
            const SizedBox(height: 20),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // A phone has no room for two panes: the list goes above the detail, so
                  // the detail's own row keeps its width.
                  if (constraints.maxWidth < 640) {
                    return Column(
                      children: [
                        SizedBox(height: 180, child: _list()),
                        const SizedBox(height: 16),
                        Expanded(child: _detail(theme)),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      SizedBox(width: 300, child: _list()),
                      const SizedBox(width: 20),
                      Expanded(child: _detail(theme)),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _list() {
    // Local mode lists what is on the device. The rows look the same as the server's,
    // because a playlist is a title, a cover and songs either way.
    if (_isLocal) {
      return ListView.builder(
        itemCount: _local.playlists.length,
        itemBuilder: (context, index) {
          final playlist = _local.playlists[index];

          return ListTile(
            leading: _Cover(cover: _covers['local:${playlist.name}'], size: 40),
            title: Text(playlist.name),
            subtitle: Text('${playlist.songs.length} Songs'),
            selected: identical(_selectedLocal, playlist),
            onTap: _busy ? null : () => _openLocal(playlist),
          );
        },
      );
    }

    return ListView.builder(
      itemCount: _playlists.length,
      itemBuilder: (context, index) {
        final playlist = _playlists[index];
        final selected = _selected?.playlist.id == playlist.id;

        return ListTile(
          leading: _Cover(cover: _covers['server:${playlist.id}'], size: 40),
          title: Text(playlist.name),
          subtitle: Text('${playlist.songCount} Songs'),
          selected: selected,
          onTap: _busy ? null : () => _open(playlist),
        );
      },
    );
  }

  Widget _detail(ThemeData theme) {
    final name = _selectedName;
    if (name == null) {
      return Text('Eine Playlist auswählen, um ihre Songs zu sehen.', style: theme.textTheme.bodyMedium);
    }

    final songs = _selectedSongs;
    final titles = _songTitles;
    // A selected playlist always has a cover key: it is made from its name or its id.
    final coverKey = _selectedCoverKey!;

    final info = Row(
      children: [
        _Cover(
          cover: _covers[coverKey],
          size: 96,
          onTap: _busy ? null : () => _pickCover(coverKey),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('${songs.length} Songs', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    );
    final start = FilledButton(onPressed: _busy ? null : _start, child: const Text('Playlist starten'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The button goes under the title when the width is a phone's, instead of
        // squeezing the title to nothing beside it.
        LayoutBuilder(
          builder: (context, constraints) => constraints.maxWidth < 520
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [info, const SizedBox(height: 12), start],
                )
              : Row(children: [Expanded(child: info), start]),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: _song >= 0 && _song < titles.length ? _song : null,
                hint: Text(
                  titles.isEmpty
                      ? (_isLocal ? 'Keine Lieder auf dem Gerät' : 'Die Bibliothek ist leer')
                      : (_isLocal ? 'Lied aus der lokalen Bibliothek wählen' : 'Lied aus der Bibliothek wählen'),
                ),
                items: [
                  for (var i = 0; i < titles.length; i++) DropdownMenuItem(value: i, child: Text(titles[i])),
                ],
                onChanged: _busy || titles.isEmpty ? null : (value) => setState(() => _song = value ?? -1),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(onPressed: _busy ? null : _addSong, child: const Text('Hinzufügen')),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: songs.isEmpty
              ? Text('Noch keine Songs. Oben ein Lied wählen und hinzufügen.', style: theme.textTheme.bodyMedium)
              : ListView.builder(
                  itemCount: songs.length,
                  itemBuilder: (context, index) {
                    final song = songs[index];
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
}

/// A playlist cover: the picked image, or a mark for the one that is still missing.
class _Cover extends StatelessWidget {
  const _Cover({required this.cover, required this.size, this.icon = Icons.album, this.onTap});

  final Uint8List? cover;
  final double size;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: size,
          height: size,
          color: scheme.surfaceContainer,
          child: cover == null
              ? Icon(icon, size: size / 2, color: scheme.onSurfaceVariant)
              : Image.memory(
                  cover!,
                  fit: BoxFit.cover,
                  // A full photo would be decoded at its own size for a thumbnail.
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
                  // A stored cover that cannot be read shows the mark, not an exception.
                  errorBuilder: (context, error, stack) =>
                      Icon(icon, size: size / 2, color: scheme.onSurfaceVariant),
                ),
        ),
      ),
    );
  }
}
