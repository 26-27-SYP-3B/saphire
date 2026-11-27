import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../core/config/api_config.dart';
import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../../core/utils/pick_image.dart';
import '../../../shared/utils/track_display.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/track_art.dart';
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

const _emptyNote =
    'Noch keine Playlist. Eine Playlist gehört dir, nicht der geteilten Bibliothek.';

/// Playlists: create one in the sheet Spotify uses, put songs in it, start it or shuffle it.
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
    this.initialId,
    this.initialLocalName,
    this.openCreate = false,
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

  /// A playlist a link picked, or a local one by name. Null opens the list without a detail.
  final int? initialId;
  final String? initialLocalName;

  /// A link may ask for the create sheet, which is what the "+" in the sidebar does.
  final bool openCreate;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
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

  /// The two fields of the sheets. They live on the page, not in the sheet, because the sheet
  /// is still built for a few frames while it closes — a controller disposed on close would be
  /// used after its end.
  final TextEditingController _createName = TextEditingController();
  final TextEditingController _songQuery = TextEditingController();

  @override
  void dispose() {
    _createName.dispose();
    _songQuery.dispose();
    super.dispose();
  }

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();
  late final CoverStore _covers = widget.covers ?? CoverStore();

  bool get _isLocal => _settings.localMode;

  /// The songs a playlist can be filled from: the shared library on the server, the songs
  /// on the device without one.
  List<String> get _songTitles => _isLocal
      ? [for (final track in _local.tracks) track.title]
      : [for (final track in _library) track.title];

  String? get _selectedName =>
      _isLocal ? _selectedLocal?.name : _selected?.playlist.name;

  /// The rows of the open playlist. A local playlist numbers its songs by their place, a
  /// server playlist by the position the server gave them; both are 1-based and contiguous.
  List<({int position, String title, int trackId})> get _selectedSongs {
    if (_isLocal) {
      final playlist = _selectedLocal;
      if (playlist == null) return const [];
      return [
        for (var i = 0; i < playlist.songs.length; i++)
          (position: i + 1, title: playlist.songs[i].title, trackId: -1),
      ];
    }
    final songs = _selected?.songs ?? const <PlaylistSong>[];
    return [
      for (final song in songs)
        (position: song.position, title: song.title, trackId: song.trackId),
    ];
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
    if (widget.openCreate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _createSheet();
      });
    }
  }

  Future<void> _load() async {
    if (_isLocal) {
      setState(() {
        _note = _local.playlists.isEmpty ? _emptyNote : null;
        _selectedLocal = _localByName(widget.initialLocalName);
      });
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
      for (final playlist in playlists) {
        if (playlist.id == widget.initialId) await _open(playlist);
      }
    } on PlaylistException catch (error) {
      if (!mounted) return;
      if (error.statusCode == 401) widget.session.clear();
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }

    try {
      final library = await widget.library.list();
      if (mounted) setState(() => _library = library);
    } on LibraryException catch (error) {
      if (mounted && _note == null) setState(() => _note = error.message);
    }
  }

  LocalPlaylist? _localByName(String? name) {
    if (name == null) return null;
    for (final playlist in _local.playlists) {
      if (playlist.name == name) return playlist;
    }
    return null;
  }

  /// The create sheet Spotify opens from "+". The cover can be picked before the playlist
  /// exists; it waits in `_newCover` until the create answered with a name or an id.
  Future<void> _createSheet() async {
    _createName.clear();
    Uint8List? cover;
    String? error;
    var sending = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Playlist erstellen',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _Cover(
                    cover: cover,
                    size: 72,
                    icon: Icons.add_photo_alternate_outlined,
                    onTap: sending
                        ? null
                        : () async {
                            final picked = await _pickCoverImage();
                            if (!context.mounted) return;
                            if (picked.error != null) {
                              setSheet(() => error = picked.error);
                              return;
                            }
                            if (picked.cover != null) {
                              setSheet(() => cover = picked.cover);
                            }
                          },
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TextField(
                      controller: _createName,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Titel der Playlist',
                      ),
                      onSubmitted: sending
                          ? null
                          : (_) async {
                              final message = await _createChecked(
                                _createName.text,
                                cover,
                              );
                              if (message == null && sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                              if (message != null) {
                                setSheet(() => error = message);
                              }
                            },
                    ),
                  ),
                ],
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: sending
                        ? null
                        : () => Navigator.pop(sheetContext),
                    child: const Text('Abbrechen'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: sending
                        ? null
                        : () async {
                            setSheet(() => sending = true);
                            final message = await _createChecked(
                              _createName.text,
                              cover,
                            );
                            if (!sheetContext.mounted) return;
                            if (message == null) {
                              Navigator.pop(sheetContext);
                            } else {
                              setSheet(() {
                                sending = false;
                                error = message;
                              });
                            }
                          },
                    child: const Text('Anlegen'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Creates a playlist and returns the message to show, or null when it worked. The page
  /// state is set here, so the sheet only has to close on null.
  Future<String?> _createChecked(String rawName, Uint8List? cover) async {
    final name = rawName.trim();
    if (_isLocal) {
      if (name.isEmpty ||
          _local.playlists.any((playlist) => playlist.name == name)) {
        return 'Bitte einen Titel eingeben, der noch nicht vergeben ist.';
      }

      _newCover = cover;
      final created = _local.createPlaylist(name);
      if (created == null) {
        return 'Bitte einen Titel eingeben, der noch nicht vergeben ist.';
      }
      final stored = await _takeCover('local:${created.name}');
      if (!mounted) return null;
      setState(() {
        _selectedLocal = created;
        _selected = null;
        _song = -1;
        _note = stored
            ? 'Playlist „${created.name}“ angelegt.'
            : 'Playlist „${created.name}“ angelegt. Das Bild konnte nicht gespeichert werden.';
      });
      return null;
    }

    setState(() => _busy = true);
    try {
      final created = await widget.playlists.create(name);
      if (!mounted) return null;
      _newCover = cover;
      final stored = await _takeCover(_serverKey(created.id));
      if (!mounted) return null;
      setState(() {
        _playlists = [..._playlists, created];
        _selected = PlaylistWithSongs(playlist: created, songs: []);
        _selectedLocal = null;
        _song = -1;
        _busy = false;
        _note = stored
            ? 'Playlist „${created.name}“ angelegt.'
            : 'Playlist „${created.name}“ angelegt. Das Bild konnte nicht gespeichert werden.';
      });
      return null;
    } on PlaylistException catch (error) {
      if (mounted) setState(() => _busy = false);
      return error.message;
    }
  }

  /// Picks and checks a cover for the create sheet. The check is the same one the detail
  /// cover uses: the picker's filter is an offer, not a check.
  Future<({Uint8List? cover, String? error})> _pickCoverImage() async {
    final Uint8List? picked;
    try {
      picked = await widget.pickImage();
    } catch (_) {
      return (cover: null, error: 'Das Bild konnte nicht gelesen werden.');
    }
    if (picked == null) return (cover: null, error: null);
    if (picked.length > maxCoverBytes) {
      return (
        cover: null,
        error: 'Das Bild ist größer als 1 MB. Bitte ein kleineres wählen.',
      );
    }
    if (!isImage(picked)) {
      return (
        cover: null,
        error: 'Die Datei ist kein Bild (PNG, JPEG, GIF oder WebP).',
      );
    }
    return (cover: picked, error: null);
  }

  /// The image picked for the playlist that is about to be created only has a key once the
  /// create answered, so it waits in `_newCover` until then. False says the storage refused it.
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
    final picked = await _pickCoverImage();
    if (!mounted) return;
    if (picked.error != null) {
      setState(() => _note = picked.error);
      return;
    }
    final cover = picked.cover;
    if (cover == null) return;

    if (key == null) {
      setState(() {
        _newCover = cover;
        _note = null;
      });
      return;
    }

    final stored = await _covers.save(key, cover);
    if (!mounted) return;
    setState(
      () => _note = stored ? null : 'Das Bild konnte nicht gespeichert werden. Es bleibt nur bis zum Neustart sichtbar.',
    );
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
      setState(
        () => _note = _isLocal
            ? 'Bitte ein Lied aus der lokalen Bibliothek wählen.'
            : 'Bitte ein Lied aus der Bibliothek wählen.',
      );
      return;
    }
    await _addSongAt(index);
  }

  /// Adds the song at [index] of the picker list to the open playlist. Shared by the compact
  /// dropdown and the "Songs hinzufügen" sheet, so both write the same positions.
  Future<void> _addSongAt(int index) async {
    if (index < 0 || index >= _songTitles.length) return;

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
      final song = await widget.playlists.addSong(
        detail.playlist.id,
        _library[index].id,
      );
      if (!mounted) return;
      setState(() {
        _selected = PlaylistWithSongs(
          playlist: detail.playlist,
          songs: [...detail.songs, song],
        );
        _note = 'Song an Position ${song.position} eingefügt.';
        _busy = false;
        _song = -1;
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
      if (playlist == null ||
          position < 1 ||
          position > playlist.songs.length) {
        return;
      }

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

      final remaining = [
        for (final song in detail.songs)
          if (song.position != position)
            song.position > position
                ? PlaylistSong(
                    position: song.position - 1,
                    trackId: song.trackId,
                    title: song.title,
                  )
                : song,
      ];

      setState(() {
        _selected = PlaylistWithSongs(
          playlist: detail.playlist,
          songs: remaining,
        );
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

  /// Puts one row of the open playlist into the queue without starting it. A server row is
  /// appended through the queue endpoint; a device row goes into the stored queue.
  Future<void> _queueSong(
    ({int position, String title, int trackId}) song,
  ) async {
    if (_isLocal) {
      final tracks = [
        for (final track in _local.tracks)
          if (track.title == song.title) track,
      ];
      if (tracks.isEmpty) return;
      _local.addToQueue(tracks.first);
      await widget.player.syncLocalQueue(_local.queue);
      if (mounted) {
        setState(() => _note = '${song.title} in die Warteschlange gelegt.');
      }
      return;
    }

    setState(() => _busy = true);
    try {
      final entry = await widget.queues.append(song.trackId);
      if (!mounted) return;
      widget.queue.append(entry.asManual());
      setState(() {
        _note = '${song.title} in die Warteschlange gelegt.';
        _busy = false;
      });
    } on QueueException catch (error) {
      if (!mounted) return;
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  /// Adds a row of the open playlist to another playlist, which is what the three-dot menu
  /// offers besides the queue and the removal.
  Future<void> _copySongTo(
    ({int position, String title, int trackId}) song,
  ) async {
    if (_isLocal) {
      final targets = [
        for (final playlist in _local.playlists)
          if (playlist.name != _selectedLocal?.name) playlist,
      ];
      if (targets.isEmpty) {
        setState(() => _note = 'Es gibt keine andere Playlist.');
        return;
      }
      final picked = await _pickPlaylist(
        targets.map((playlist) => playlist.name).toList(),
      );
      if (picked == null || !mounted) return;
      final target = targets.firstWhere((playlist) => playlist.name == picked);
      final track = [
        for (final track in _local.tracks)
          if (track.title == song.title) track,
      ];
      if (track.isEmpty) return;
      _local.addToPlaylist(target, track.first);
      setState(() => _note = 'Song zur Playlist „${target.name}“ hinzugefügt.');
      return;
    }

    final targets = [
      for (final playlist in _playlists)
        if (playlist.id != _selected?.playlist.id) playlist,
    ];
    if (targets.isEmpty) {
      setState(() => _note = 'Es gibt keine andere Playlist.');
      return;
    }
    final picked = await _pickPlaylist([
      for (final playlist in targets) playlist.name,
    ]);
    if (picked == null || !mounted) return;
    final target = targets.firstWhere((playlist) => playlist.name == picked);

    setState(() => _busy = true);
    try {
      final added = await widget.playlists.addSong(target.id, song.trackId);
      if (!mounted) return;
      setState(() {
        _note =
            'Song an Position ${added.position} zur Playlist „${target.name}“ hinzugefügt.';
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

  Future<String?> _pickPlaylist(List<String> names) =>
      showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Zu Playlist hinzufügen',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ),
              for (final name in names)
                ListTile(
                  leading: const TrackArt(size: 40, icon: Icons.queue_music),
                  title: Text(name),
                  onTap: () => Navigator.pop(context, name),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );

  /// The full picker behind "Songs hinzufügen": a field and the library, so a long playlist
  /// can be filled without the small dropdown. Picking a row adds it and closes the sheet.
  Future<void> _addSongSheet() async {
    _songQuery.clear();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) {
          final titles = _songTitles;
          final needle = _songQuery.text.trim().toLowerCase();
          final matches = [
            for (var i = 0; i < titles.length; i++)
              if (titles[i].toLowerCase().contains(needle)) i,
          ];

          return SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Songs hinzufügen',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _songQuery,
                        autofocus: true,
                        onChanged: (_) => setSheet(() {}),
                        decoration: const InputDecoration(
                          hintText: 'Songs suchen',
                          prefixIcon: Icon(Icons.search),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: matches.isEmpty
                      ? Center(
                          child: Text(
                            titles.isEmpty
                                ? 'Die Bibliothek ist leer.'
                                : 'Keine Songs gefunden.',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: matches.length,
                          itemBuilder: (context, position) {
                            final index = matches[position];
                            return ListTile(
                              leading: TrackArt(size: 40),
                              title: Text(
                                titles[index],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: const Icon(Icons.add),
                              onTap: () async {
                                await _addSongAt(index);
                                if (sheetContext.mounted) {
                                  Navigator.pop(sheetContext);
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _start({bool shuffle = false}) async {
    if (_isLocal) {
      final playlist = _selectedLocal;
      if (playlist == null) return;
      if (playlist.songs.isEmpty) {
        setState(() => _note = 'Diese Playlist hat noch keine Lieder.');
        return;
      }

      _local.setQueue(playlist.songs, fromName: playlist.name);
      widget.player.shuffle = shuffle;
      setState(() => _busy = true);
      try {
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
      final entries = await widget.queues.fill(
        QueueSource.playlist(detail.playlist.id),
      );
      if (!mounted) return;
      widget.queue.fill(entries, fromName: detail.playlist.name);
      widget.player.shuffle = shuffle;
      await widget.player.playCurrent();
      if (!mounted) return;
      setState(() => _note = null);
    } on QueueException catch (error) {
      if (!mounted) return;
      setState(() => _note = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _note = switch (error) {
          PlaybackException(:final message) => message,
          _ => 'Das Lied konnte nicht gespielt werden: $error',
        },
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppShell(
      selected: '/playlists',
      player: widget.player,
      queues: widget.queues,
      playlists: widget.playlists,
      library: widget.library,
      session: widget.session,
      localMode: _isLocal,
      localLibrary: _local,
      sidebarPlaylists: _playlists,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Playlists', style: theme.textTheme.displaySmall),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _createSheet,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Playlist erstellen'),
                ),
              ],
            ),
            if (_note != null) ...[
              const SizedBox(height: 12),
              Text(
                _note!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
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
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: _Cover(cover: _covers['local:${playlist.name}'], size: 48),
            title: Text(
              playlist.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: _Cover(cover: _covers[_serverKey(playlist.id)], size: 48),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text('${playlist.songCount} Songs'),
          selected: selected,
          onTap: _busy ? null : () => _open(playlist),
        );
      },
    );
  }

  /// The library row behind one playlist entry. A server playlist stores references, so the
  /// artist and length come from the library the page read; a local playlist holds the whole
  /// song, so its tags are already there.
  Track? _trackFor(
    ({int position, String title, int trackId}) song,
    int index,
  ) {
    if (_isLocal) {
      final playlist = _selectedLocal;
      if (playlist == null || index >= playlist.songs.length) return null;
      return playlist.songs[index].toTrack();
    }
    for (final track in _library) {
      if (track.id == song.trackId) return track;
    }
    return null;
  }

  Widget _detail(ThemeData theme) {
    final name = _selectedName;
    if (name == null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          'Eine Playlist auswählen, um ihre Songs zu sehen.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    final songs = _selectedSongs;
    final titles = _songTitles;
    final coverKey = _selectedCoverKey!;
    // A phone's detail pane is short: a smaller cover leaves room for the controls and the
    // first songs without the pane overflowing.
    final compact = MediaQuery.sizeOf(context).width < 640;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        _Cover(
          cover: _covers[coverKey],
          size: compact ? 96 : 140,
          radius: 8,
          onTap: _busy ? null : () => _pickCover(coverKey),
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PLAYLIST',
                style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
              ),
              const SizedBox(height: 6),
              Text(
                name,
                style: theme.textTheme.displaySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                '${songs.length} Songs',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _start(),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Playlist starten'),
                  ),
                  IconButton.filledTonal(
                    tooltip: 'Zufällige Wiedergabe',
                    onPressed: _busy ? null : () => _start(shuffle: true),
                    icon: const Icon(Icons.shuffle),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        header,
        const SizedBox(height: 20),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _addSongSheet,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Songs hinzufügen'),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Playlist-Cover ändern',
              onPressed: _busy ? null : () => _pickCover(coverKey),
              icon: const Icon(Icons.add_photo_alternate_outlined),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: _song >= 0 && _song < titles.length ? _song : null,
                hint: Text(
                  titles.isEmpty
                      ? (_isLocal
                            ? 'Keine Lieder auf dem Gerät'
                            : 'Die Bibliothek ist leer')
                      : (_isLocal
                            ? 'Lied aus der lokalen Bibliothek wählen'
                            : 'Lied aus der Bibliothek wählen'),
                ),
                items: [
                  for (var i = 0; i < titles.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(titles[i], overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: _busy || titles.isEmpty
                    ? null
                    : (value) => setState(() => _song = value ?? -1),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: _busy ? null : _addSong,
              child: const Text('Hinzufügen'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (songs.isEmpty)
          Align(
            alignment: Alignment.topLeft,
            child: Text(
              'Noch keine Songs. Oben ein Lied wählen und hinzufügen.',
              style: theme.textTheme.bodyMedium,
            ),
          )
        else
          for (var index = 0; index < songs.length; index++)
            Builder(
              builder: (context) {
                final song = songs[index];
                final track = _trackFor(song, index);
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: SizedBox(
                    width: 66,
                    child: Row(
                      children: [
                        SizedBox(width: 18, child: Text('${song.position}')),
                        TrackArt(cover: track?.cover, size: 40),
                      ],
                    ),
                  ),
                  title: Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: track == null
                      ? null
                      : Text(
                          displayMeta(track),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'Aktionen für ${song.title}',
                    onSelected: (value) {
                      if (value == 'queue') {
                        _queueSong(song);
                      } else if (value == 'copy') {
                        _copySongTo(song);
                      } else {
                        _removeSong(song.position);
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'queue',
                        child: Text('Zur Warteschlange hinzufügen'),
                      ),
                      PopupMenuItem(
                        value: 'copy',
                        child: Text('Zu Playlist hinzufügen'),
                      ),
                      PopupMenuItem(value: 'remove', child: Text('Entfernen')),
                    ],
                  ),
                );
              },
            ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// A playlist cover: the picked image, or a mark for the one that is still missing.
class _Cover extends StatelessWidget {
  const _Cover({
    required this.cover,
    required this.size,
    this.icon = Icons.album,
    this.onTap,
    this.radius = 6,
  });

  final Uint8List? cover;
  final double size;
  final IconData icon;
  final VoidCallback? onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: size,
          height: size,
          color: scheme.surfaceContainer,
          child: cover == null
              ? Icon(icon, size: size / 2, color: scheme.onSurfaceVariant)
              : Image.memory(
                  cover!,
                  fit: BoxFit.cover,
                  cacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
                      .round(),
                  errorBuilder: (context, error, stack) => Icon(
                    icon,
                    size: size / 2,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
    );
  }
}
