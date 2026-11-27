import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../../core/utils/audio_format.dart';
import '../../../core/utils/pick_audio.dart';
import '../../../shared/domain/track.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../../shared/widgets/track_art.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../playlists/domain/playlist.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/player.dart';
import '../../player/domain/queue.dart';
import '../../upload/data/upload_repository.dart';
import '../data/library_repository.dart';
import '../data/local_library.dart';
import '../domain/local_playlist.dart';
import '../domain/local_track.dart';

/// The three the song list can be ordered by. There is nothing else to order by.
const sortKeys = ['Titel', 'Interpret', 'Hinzugefügt am'];

/// The categories the filter offers, in the order the panel shows them. Every value of a
/// category is read from the songs themselves, so the filter cannot offer something the list
/// cannot show.
const filterKeys = ['Interpret', 'Album', 'Genre', 'Erscheinungsjahr'];

/// What a filter calls a song that does not have a value for a category. It is a real value
/// that can be picked, not a gap: a song with no genre is still a song the user may want.
const unknownFilter = 'Unbekannt';

/// The window height the inline filter panel needs. The page body is shorter than the window
/// by the player bar and, on a narrow page, the bottom navigation, so a window that merely
/// clears the panel's own height would clip its footer.
const filterPanelMinHeight = 860.0;

/// The artist shown for a row: what the file's tags name (api-docs.md, the artist field).
/// Only a title that is still the name the client sent can be read as "interpret - titel",
/// because that pattern is a naming habit, not something a tag says. A title that came from
/// a tag is not a name, so nothing is guessed from it and the row shows a dash.
String artistOf(Track track) => track.artist.isNotEmpty
    ? track.artist
    : (looksLikeFileName(track.title) ? artistFromName(track.title) : '');

/// The extensions a song can have (see `audioExtensions`), so a title ending in one of them is
/// the name it was stored under rather than a tagged title.
final fileExtensions = [
  for (final extension in audioExtensions) extension.substring(1),
];

bool looksLikeFileName(String title) {
  final dot = title.lastIndexOf('.');
  return dot > 0 &&
      fileExtensions.contains(title.substring(dot + 1).toLowerCase());
}

/// The naming habit of an untagged file: "interpret - titel.mp3".
String artistFromName(String title) {
  final split = title.indexOf(' - ');
  return split < 1 ? '' : title.substring(0, split);
}

/// What a row shows where nothing is known: no artist, no length. A dash is honest where a
/// guess would not be.
const unknownValue = '–';

/// A row shows the length as mm:ss. A file the server could not measure shows the dash,
/// because the server can only know it for MPEG Layer III (see server/metadata.rs).
String durationOf(Track track) {
  if (track.durationMs <= 0) return unknownValue;

  final seconds = track.durationMs ~/ 1000;
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// A view of the library that is not the plain song list. The four chips Spotify puts above
/// "Deine Bibliothek" are the same four here; the song list is what no chip selected shows.
enum LibraryView { songs, playlists, albums, artists, local }

/// One group in the album or artist view: a name, the songs behind it and the first cover the
/// songs carry. The rows are built from this, so the grid and the list show the same thing.
class _Group {
  _Group(this.name);

  final String name;
  final List<Track> tracks = [];
  Uint8List? cover;
  String subtitle = '';

  void add(Track track) {
    tracks.add(track);
    cover ??= track.cover;
  }
}

/// The library: the songs the server has and the songs on this device in one place, Spotify's
/// filter chips above them, the sort and the metadata filter below, and a list or a grid.
///
/// The four chips are views, not filters on the same list: Playlists shows the caller's
/// playlists, Alben and Künstler*innen group the songs, Lokal keeps the device songs and the
/// unselected chip is the whole song list. A group opens that album or artist as a song list,
/// so a chip never hides a song for good.
///
/// Playing goes through the shared queue rather than through a second player: a song opened
/// here and a song opened from a playlist play exactly the same way, and the bar at the bottom
/// shows the same song as the queue.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.library,
    required this.playlists,
    required this.queues,
    required this.queue,
    required this.player,
    required this.uploads,
    required this.session,
    this.pickAudio = pickAudioFiles,
    this.pickLocal = pickLocalAudioFiles,
    this.pickFolder = pickLocalFolder,
    this.settings,
    this.localLibrary,
    this.initialTrackId,
    this.initialView,
  });

  final LibraryRepository library;
  final PlaylistRepository playlists;
  final QueueRepository queues;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final UploadRepository uploads;

  /// What the queue frame needs: the session the queue calls are made with.
  final SessionStore session;
  final PickAudio pickAudio;
  final PickLocalAudio pickLocal;
  final PickLocalAudio pickFolder;

  /// Null in a test that does not care about local mode: the stores then stay in memory.
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;

  /// A song a link named. The list opens and plays that song once it has been read, so a shared
  /// `/library?track=<id>` address is the same as tapping the row. Null when the page was opened
  /// without a link.
  final int? initialTrackId;

  /// The chip a link picked: `albums`, `artists`, `local` or `playlists`. Null opens the songs.
  final String? initialView;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _search = TextEditingController();

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  String _sort = sortKeys.first;
  LibraryView _view = LibraryView.songs;
  bool _grid = false;
  List<Track> _tracks = [];
  List<Playlist> _playlists = [];

  /// The picked values per category. A category with several values matches songs that have
  /// any of them; two categories must both match. Empty means no filter, not "nothing".
  final Map<String, Set<String>> _filters = {};

  /// Whether the wide layout shows the filter panel below the sort. On a phone the panel is
  /// an overlay instead, so this stays false there.
  bool _filtersOpen = false;

  String? _note;

  // Reading the list and sending a batch are two different things. One flag for both would
  // make the button say "Wird hochgeladen…" while nothing is being uploaded.
  bool _loading = false;
  bool _picking = false;
  bool _uploading = false;
  bool _busy = false;

  // What the message is about. Only a failed read can be retried here; a file the server
  // refused has to be chosen again, so its message must not offer a retry.
  bool _noteIsReadError = false;

  // The link is answered once: a later read of the list must not start the song again.
  bool _openedLink = false;

  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _view = switch (widget.initialView) {
      'playlists' => LibraryView.playlists,
      'albums' => LibraryView.albums,
      'artists' => LibraryView.artists,
      'local' => LibraryView.local,
      _ => LibraryView.songs,
    };
    if (!_settings.localMode) {
      _load();
      _loadPlaylists();
    } else if (widget.initialTrackId != null) {
      _openedLink = true;
      _note = 'Das verlinkte Lied ist nicht in der Bibliothek.';
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);

    try {
      final tracks = await widget.library.list();
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _note = null;
        _noteIsReadError = false;
      });
      await _openLinkedSong(tracks);
    } on LibraryException catch (error) {
      if (mounted) {
        setState(() {
          _note = error.message;
          _noteIsReadError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Plays the song a link named. A link that names a song the library does not have says so
  /// instead of opening a different one, and plays nothing.
  Future<void> _openLinkedSong(List<Track> tracks) async {
    final linkId = widget.initialTrackId;
    if (linkId == null || _openedLink) return;
    _openedLink = true;

    Track? linked;
    for (final track in tracks) {
      if (track.id == linkId) {
        linked = track;
        break;
      }
    }
    if (linked == null) {
      if (mounted) {
        setState(
          () => _note = 'Das verlinkte Lied ist nicht in der Bibliothek.',
        );
      }
      return;
    }
    await _play(linked);
    if (widget.queue.current?.trackId != linked.id) _openedLink = false;
  }

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await widget.playlists.list();
      if (mounted) setState(() => _playlists = playlists);
    } on PlaylistException catch (error) {
      if (mounted && _note == null) {
        setState(() {
          _note = error.message;
          _noteIsReadError = false;
        });
      }
    }
  }

  Future<void> _upload() async {
    if (_picking) return;
    setState(() => _picking = true);

    final List<PickedAudio>? picked;
    try {
      picked = await widget.pickAudio();
    } catch (error) {
      if (mounted) {
        setState(() {
          _note =
              'Die Dateien konnten nicht gelesen werden. Versuch es erneut.';
          _noteIsReadError = false;
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }

    if (picked == null) return;

    setState(() => _uploading = true);
    try {
      for (final file in picked) {
        try {
          final track = await widget.uploads.upload(
            filename: file.name,
            bytes: file.bytes,
          );
          if (!mounted) return;
          setState(() => _tracks.add(track));
        } on UploadException catch (error) {
          if (mounted) {
            setState(() {
              _note = '${file.name}: ${error.message}';
              _noteIsReadError = false;
            });
          }
        }
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Adds picked files to the local library. Each file is checked on its own, so a refused
  /// one says why and the rest still land in the library. `folder` takes a directory instead.
  Future<void> _addLocal({bool folder = false}) async {
    if (_picking) return;
    setState(() => _picking = true);

    final List<PickedLocal>? picked;
    try {
      picked = await (folder ? widget.pickFolder() : widget.pickLocal());
    } on UnsupportedError catch (error) {
      if (mounted) setState(() => _note = '${error.message}');
      return;
    } catch (_) {
      if (mounted) {
        setState(
          () => _note = folder
              ? 'Dieser Ordner konnte nicht gelesen werden. Wähle die Songs stattdessen einzeln aus.'
              : 'Die Dateien konnten nicht gelesen werden. Versuch es erneut.',
        );
      }
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (picked == null || !mounted) return;

    if (picked.isEmpty) {
      if (folder) {
        setState(() => _note = 'In diesem Ordner sind keine Audiodateien.');
      }
      return;
    }

    setState(() {
      for (final file in picked!) {
        final refused = _local.add(
          name: file.name,
          path: file.path,
          bytes: file.bytes,
        );
        if (refused != null) _note = '${file.name}: $refused';
      }
    });
  }

  Future<void> _control(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on QueueException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } on PlaylistException catch (error) {
      if (mounted) setState(() => _note = error.message);
    } catch (error) {
      if (mounted) setState(() => _note = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opening a row fills the queue with that one song and plays it, the way the Playlists
  /// page starts a playlist. A song on this device plays straight from the file.
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
    if (mounted) widget.queue.append(entry.asManual());
  });

  Future<void> _addToPlaylist(Track track, String? value) async {
    if (value == null) return;
    await _control(() async {
      if (track.isLocal) {
        LocalPlaylist? playlist;
        if (value == 'new-local') {
          playlist = _local.createPlaylist('Meine Playlist');
          if (playlist == null) {
            if (mounted) {
              setState(
                () => _note = 'Der Name „Meine Playlist“ ist schon vergeben.',
              );
            }
            return;
          }
        } else {
          for (final entry in _local.playlists) {
            if (entry.name == value) playlist = entry;
          }
        }
        if (playlist == null) return;
        _local.addToPlaylist(playlist, track.toLocalTrack());
        if (mounted) {
          setState(
            () => _note = 'Song zur Playlist „${playlist!.name}“ hinzugefügt.',
          );
        }
        return;
      }

      var id = int.tryParse(value);
      if (id == null || id == 0) {
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

  /// Every song, server and device, in the shared shape. The device ids are negative and
  /// distinct, so the order of two local rows is stable.
  List<Track> _all() => [
    ..._tracks,
    for (var index = 0; index < _local.tracks.length; index++)
      _local.tracks[index].toTrack(id: -index - 1),
  ];

  String _artistOf(Track track) =>
      track.isLocal ? track.artist : artistOf(track);

  String _filterValue(Track track, String category) => switch (category) {
    'Interpret' => _artistOf(track).isEmpty ? unknownFilter : _artistOf(track),
    'Album' => track.album.isEmpty ? unknownFilter : track.album,
    'Genre' => track.genre.isEmpty ? unknownFilter : track.genre,
    _ => track.year == 0 ? unknownFilter : '${track.year}',
  };

  Map<String, List<String>> _filterOptions() {
    final tracks = _all();
    return {
      for (final category in filterKeys)
        category:
            ({for (final track in tracks) _filterValue(track, category)}
                .toList()
              ..sort((a, b) {
                if (category != 'Erscheinungsjahr') {
                  return a.toLowerCase().compareTo(b.toLowerCase());
                }
                if (a == unknownFilter) return 1;
                if (b == unknownFilter) return -1;
                return int.parse(b).compareTo(int.parse(a));
              })),
    };
  }

  bool _matchesFilters(Track track) {
    for (final category in filterKeys) {
      final chosen = _filters[category];
      if (chosen == null || chosen.isEmpty) continue;
      if (!chosen.contains(_filterValue(track, category))) return false;
    }
    return true;
  }

  void _toggleFilter(
    Map<String, Set<String>> filters,
    String category,
    String value,
  ) {
    final values = filters.putIfAbsent(category, () => <String>{});
    if (!values.remove(value)) values.add(value);
    if (values.isEmpty) filters.remove(category);
  }

  void _removeFilter(String category, String value) {
    final values = _filters[category];
    if (values == null) return;
    values.remove(value);
    if (values.isEmpty) _filters.remove(category);
  }

  void _resetFilters() => setState(_filters.clear);

  Map<String, Set<String>> _copyFilters() => {
    for (final entry in _filters.entries) entry.key: {...entry.value},
  };

  bool _inlineFilters(BuildContext context) {
    final room = MediaQuery.sizeOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return room.width >= 700 && room.height >= filterPanelMinHeight * textScale;
  }

  Future<void> _openFilters() async {
    final options = _filterOptions();

    if (_inlineFilters(context)) {
      setState(() => _filtersOpen = !_filtersOpen);
      return;
    }

    var picked = _copyFilters();
    final applied = await showModalBottomSheet<Map<String, Set<String>>>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: _filterPanel(
            options: options,
            selected: picked,
            onToggle: (category, value) =>
                setSheet(() => _toggleFilter(picked, category, value)),
            onReset: () => setSheet(() {
              picked = {};
            }),
            onApply: () => Navigator.pop(sheetContext, {
              for (final entry in picked.entries) entry.key: {...entry.value},
            }),
          ),
        ),
      ),
    );

    if (applied != null && mounted) {
      setState(() {
        _filters
          ..clear()
          ..addAll(applied);
      });
    }
  }

  /// What the song list shows: the search, every picked filter and, in the local view, only
  /// the songs on this device.
  List<Track> _visible() {
    final query = _search.text.trim().toLowerCase();
    final rows = [
      for (final track in _all())
        if ((_view != LibraryView.local || track.isLocal) &&
            (query.isEmpty ||
                track.title.toLowerCase().contains(query) ||
                _artistOf(track).toLowerCase().contains(query)) &&
            _matchesFilters(track))
          track,
    ];

    switch (_sort) {
      case 'Interpret':
        rows.sort((a, b) {
          final byArtist = _artistOf(a)
              .toLowerCase()
              .compareTo(_artistOf(b).toLowerCase());
          return byArtist != 0 ? byArtist : a.id.compareTo(b.id);
        });
      case 'Hinzugefügt am':
        rows.sort(
          (a, b) => b.uploadedAt != a.uploadedAt
              ? b.uploadedAt.compareTo(a.uploadedAt)
              : b.id.compareTo(a.id),
        );
      default:
        rows.sort((a, b) {
          final byTitle = a.title.toLowerCase().compareTo(
            b.title.toLowerCase(),
          );
          return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
        });
    }
    return rows;
  }

  /// The groups of the album and artist views. The songs are the same ones the list shows, so
  /// the counts and names cannot drift apart.
  List<_Group> _groups(LibraryView view) {
    final groups = <String, _Group>{};
    for (final track in _all()) {
      final name = switch (view) {
        LibraryView.albums => track.album.isEmpty ? unknownFilter : track.album,
        _ => _artistOf(track).isEmpty ? unknownFilter : _artistOf(track),
      };
      groups.putIfAbsent(name, () => _Group(name)).add(track);
    }
    for (final group in groups.values) {
      final artists = {
        for (final track in group.tracks)
          if (_artistOf(track).isNotEmpty) _artistOf(track),
      };
      group.subtitle = view == LibraryView.albums
          ? (artists.isEmpty ? unknownValue : artists.join(', '))
          : '${group.tracks.length} ${group.tracks.length == 1 ? 'Song' : 'Songs'}';
    }
    return groups.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  void _openGroup(LibraryView view, _Group group) {
    setState(() {
      _view = LibraryView.songs;
      _filters.clear();
      _filters[view == LibraryView.albums ? 'Album' : 'Interpret'] = {
        group.name,
      };
      _filtersOpen = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _visible();
    final total = _tracks.length + _local.tracks.length;
    final shownTotal = _view == LibraryView.local
        ? [
            for (final t in _all())
              if (t.isLocal) t,
          ].length
        : total;
    final filtering = _filters.isNotEmpty;
    final searching = _search.text.trim().isNotEmpty;
    final filterCount = _filters.values.fold<int>(
      0,
      (sum, values) => sum + values.length,
    );
    final inlineFilters = _inlineFilters(context);
    final songsView = _view == LibraryView.songs || _view == LibraryView.local;
    // A phone keeps only the view chips above the list; the sort is a menu-shaped control on
    // Spotify's phone library too, and the chips would push the first songs below the fold.
    final phone = MediaQuery.sizeOf(context).width < 600;

    return AppShell(
      selected: '/library',
      player: widget.player,
      queues: widget.queues,
      playlists: widget.playlists,
      library: widget.library,
      session: widget.session,
      localMode: _settings.localMode,
      localLibrary: _local,
      sidebarPlaylists: _playlists,
      // The whole page scrolls as one list, the way Spotify's library does. The header is the
      // first child instead of a fixed block, so a phone with a filter applied does not run out
      // of room above the songs.
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Bibliothek', style: theme.textTheme.displaySmall),
                      const SizedBox(height: 4),
                      if (!_loading && shownTotal > 0)
                        Text(
                          songsView
                              ? (!filtering && !searching
                                    ? '$shownTotal Songs'
                                    : '${rows.length} von $shownTotal Songs passen '
                                          '${filtering && searching
                                              ? 'zu Suche und Filter'
                                              : filtering
                                              ? 'zu den Filtern'
                                              : 'zur Suche'}')
                              : _view == LibraryView.playlists
                              ? '${_playlists.length + _local.playlists.length} Playlists'
                              : '${_groups(_view).length} ${_view == LibraryView.albums ? 'Alben' : 'Künstler*innen'}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!_settings.localMode &&
                    MediaQuery.sizeOf(context).width >= 600)
                  FilledButton.tonal(
                    onPressed: _loading || _picking || _uploading
                        ? null
                        : _upload,
                    child: Text(
                      _uploading ? 'Wird hochgeladen…' : 'Song hochladen',
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Hinzufügen',
                  onPressed: _showAddSheet,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      hintText: 'Songs suchen',
                      prefixIcon: Icon(Icons.search, size: 18),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // The filter stays beside the search, where it is reachable without scrolling
                // even in a short landscape window; the sort chips can scroll with the page.
                TextButton(
                  onPressed: _openFilters,
                  child: Text(
                    filterCount == 0 ? 'Filter' : 'Filter ($filterCount)',
                  ),
                ),
                if (phone)
                  PopupMenuButton<String>(
                    tooltip: 'Sortieren',
                    icon: const Icon(Icons.sort, size: 20),
                    onSelected: (key) => setState(() => _sort = key),
                    itemBuilder: (context) => [
                      for (final key in sortKeys)
                        CheckedPopupMenuItem(value: key, checked: key == _sort, child: Text(key)),
                    ],
                  ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _grid ? 'Liste' : 'Raster',
                  onPressed: () => setState(() => _grid = !_grid),
                  icon: Icon(_grid ? Icons.view_list : Icons.grid_view),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _viewChip('Playlists', LibraryView.playlists),
                _viewChip('Alben', LibraryView.albums),
                _viewChip('Künstler*innen', LibraryView.artists),
                _viewChip('Lokal', LibraryView.local),
                if (songsView && !phone)
                  for (final key in sortKeys) _sortChip(key),
              ],
            ),
          ),
          if (songsView && _filters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final category in filterKeys)
                    for (final value in _filters[category] ?? const <String>{})
                      InputChip(
                        label: Text('$category: $value'),
                        onDeleted: () =>
                            setState(() => _removeFilter(category, value)),
                        deleteButtonTooltipMessage:
                            'Filter $category: $value entfernen',
                      ),
                  TextButton(
                    onPressed: _resetFilters,
                    child: const Text('Filter zurücksetzen'),
                  ),
                ],
              ),
            ),
          if (songsView && _filtersOpen && inlineFilters)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: _filterPanel(
                options: _filterOptions(),
                selected: _filters,
                onToggle: (category, value) =>
                    setState(() => _toggleFilter(_filters, category, value)),
                onReset: _resetFilters,
                showReset: false,
              ),
            ),
          if (_note != null && !_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(_note!, style: TextStyle(color: scheme.error)),
                  ),
                  if (_noteIsReadError)
                    TextButton(
                      onPressed: _load,
                      child: const Text('Erneut versuchen'),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          if (_loading)
            _loadingState()
          else if (_view == LibraryView.playlists)
            ..._playlistChildren()
          else if (_view == LibraryView.albums || _view == LibraryView.artists)
            ..._groupChildren(_view)
          else
            ..._songChildren(rows, searching, filtering),
        ],
      ),
    );
  }

  Widget _viewChip(String label, LibraryView view) {
    final selected = _view == view;
    return FilterChip(
      key: ValueKey('view-${view.name}'),
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() {
        _view = selected ? LibraryView.songs : view;
        _filtersOpen = false;
      }),
    );
  }

  Widget _sortChip(String key) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picked = key == _sort;

    return Semantics(
      button: true,
      selected: picked,
      child: InkWell(
        onTap: () => setState(() => _sort = key),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: picked ? scheme.primary : fieldBackground,
            border: Border.all(color: picked ? scheme.primary : scheme.outline),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            key,
            style: theme.textTheme.labelSmall?.copyWith(
              color: picked ? Colors.white : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  /// The children of the page list for the song view: the rows, or the cards when the grid
  /// was picked, or the sentence that says why there is nothing.
  List<Widget> _songChildren(List<Track> rows, bool searching, bool filtering) {
    if (rows.isEmpty) return [_empty(searching, filtering)];
    if (_grid) {
      return [
        _gridWrap([for (final track in rows) _songCard(track)]),
      ];
    }
    return [
      for (final track in rows) _songRow(track),
      const SizedBox(height: 24),
    ];
  }

  /// Cards in the same flow as the list: a Wrap keeps them part of the page list, so the header
  /// and the cards scroll together instead of two nested scroll areas fighting for a finger.
  Widget _gridWrap(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = constraints.maxWidth >= 1200
            ? 5
            : constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 600
            ? 3
            : 2;
        const spacing = 12.0;
        final width =
            (constraints.maxWidth - 48 - (count - 1) * spacing) / count;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Wrap(
            spacing: spacing,
            runSpacing: 16,
            children: [
              for (final card in cards)
                SizedBox(width: width, height: width + 64, child: card),
            ],
          ),
        );
      },
    );
  }

  /// One song: its cover, name, what is known about it and the actions the menu has. The whole
  /// row can be tapped, so playing a song does not need the small icon.
  Widget _songRow(Track track) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = widget.player.localCurrent;
    final current = track.isLocal
        ? local != null &&
              local.path == track.localPath &&
              local.title == track.title
        : widget.queue.current?.trackId == track.id;
    final artist = _artistOf(track);

    return InkWell(
      onTap: _busy ? null : () => _play(track),
      onSecondaryTapDown: (details) =>
          _contextMenu(details.globalPosition, track),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: current ? scheme.surfaceContainer : null,
          border: Border(
            left: BorderSide(
              color: current ? scheme.primary : Colors.transparent,
              width: 2,
            ),
            bottom: const BorderSide(color: hairline),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Abspielen',
              onPressed: _busy ? null : () => _play(track),
              icon: TrackArt(cover: track.cover, size: 44),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          track.title,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: current ? scheme.primary : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (track.isLocal) ...[
                        const SizedBox(width: 8),
                        const SourceBadge(local: true),
                      ],
                    ],
                  ),
                  Text(
                    track.isLocal
                        ? (artist.isEmpty ? 'Auf diesem Gerät' : artist)
                        : (artist.isEmpty ? unknownValue : artist),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              durationOf(track),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            _menu(track),
          ],
        ),
      ),
    );
  }

  Widget _songCard(Track track) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: _busy ? null : () => _play(track),
      onSecondaryTapDown: (details) =>
          _contextMenu(details.globalPosition, track),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => TrackArt(
                cover: track.cover,
                size: constraints.maxWidth,
                radius: 8,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            track.title,
            style: theme.textTheme.labelLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            track.isLocal
                ? 'Lokal'
                : (_artistOf(track).isEmpty ? unknownValue : _artistOf(track)),
            style: theme.textTheme.bodySmall?.copyWith(color: mutedText),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _menu(Track track) {
    return PopupMenuButton<String>(
      tooltip: 'Aktionen für ${track.title}',
      onSelected: (value) {
        if (value == 'queue') {
          _addToQueue(track);
        } else {
          _addToPlaylist(track, value);
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
              value: 'new-local',
              child: Text('Zur neuen lokalen Playlist „Meine Playlist“'),
            )
          else
            for (final playlist in _local.playlists)
              PopupMenuItem(
                value: playlist.name,
                child: Text('Zur Playlist „${playlist.name}“'),
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
                child: Text('Zur Playlist „${playlist.name}“'),
              ),
        ],
      ],
    );
  }

  /// A right click on a row opens the same actions the three-dot menu has, at the pointer. It
  /// is what a desktop user tries before looking for a menu button.
  Future<void> _contextMenu(Offset position, Track track) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;

    final value = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'queue',
          child: Text('Zur Warteschlange hinzufügen'),
        ),
        if (!track.isLocal && _playlists.isEmpty)
          const PopupMenuItem(
            value: 'new',
            child: Text('Zur neuen Playlist „Meine Playlist“'),
          )
        else if (!track.isLocal)
          for (final playlist in _playlists)
            PopupMenuItem(
              value: '${playlist.id}',
              child: Text('Zur Playlist „${playlist.name}“'),
            )
        else if (_local.playlists.isEmpty)
          const PopupMenuItem(
            value: 'new-local',
            child: Text('Zur neuen lokalen Playlist „Meine Playlist“'),
          )
        else
          for (final playlist in _local.playlists)
            PopupMenuItem(
              value: playlist.name,
              child: Text('Zur Playlist „${playlist.name}“'),
            ),
      ],
    );
    if (value == null) return;
    if (value == 'queue') {
      await _addToQueue(track);
    } else {
      await _addToPlaylist(track, value);
    }
  }

  List<Widget> _playlistChildren() {
    final local = [for (final playlist in _local.playlists) playlist];
    if (_playlists.isEmpty && local.isEmpty) {
      return [
        _emptyMessage(
          'Noch keine Playlist. Eine Playlist gehört dir, nicht der geteilten Bibliothek.',
        ),
      ];
    }

    if (_grid) {
      return [
        _gridWrap([
          for (final playlist in _playlists)
            _playlistCard(
              playlist.name,
              'Playlist · ${playlist.songCount} Songs',
              () => context.go('/playlists?id=${playlist.id}'),
            ),
          for (final playlist in local)
            _playlistCard(
              playlist.name,
              'Lokal · ${playlist.songs.length} Songs',
              () => context.go(
                '/playlists?local=${Uri.encodeComponent(playlist.name)}',
              ),
            ),
        ]),
      ];
    }

    return [
      for (final playlist in _playlists)
        _playlistRow(
          name: playlist.name,
          subtitle: 'Playlist · ${playlist.songCount} Songs',
          onTap: () => context.go('/playlists?id=${playlist.id}'),
        ),
      for (final playlist in local)
        _playlistRow(
          name: playlist.name,
          subtitle: 'Lokal · ${playlist.songs.length} Songs',
          onTap: () => context.go(
            '/playlists?local=${Uri.encodeComponent(playlist.name)}',
          ),
        ),
      const SizedBox(height: 24),
    ];
  }

  Widget _playlistCard(String name, String subtitle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => TrackArt(
                size: constraints.maxWidth,
                radius: 8,
                icon: Icons.queue_music,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            style: Theme.of(context).textTheme.labelLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: mutedText),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _playlistRow({
    required String name,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: const TrackArt(size: 48, icon: Icons.queue_music),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(color: mutedText),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  List<Widget> _groupChildren(LibraryView view) {
    final groups = _groups(view);
    if (groups.isEmpty) return [_emptyMessage('Die Bibliothek ist noch leer.')];

    if (_grid) {
      return [
        _gridWrap([for (final group in groups) _groupCard(view, group)]),
      ];
    }

    return [
      for (final group in groups)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: TrackArt(
            cover: group.cover,
            size: 48,
            icon: view == LibraryView.albums ? Icons.album : Icons.person,
          ),
          title: Text(group.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${group.subtitle} · ${group.tracks.length} Songs',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: mutedText),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _openGroup(view, group),
        ),
      const SizedBox(height: 24),
    ];
  }

  Widget _groupCard(LibraryView view, _Group group) {
    return InkWell(
      onTap: () => _openGroup(view, group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => TrackArt(
                cover: group.cover,
                size: constraints.maxWidth,
                radius: 8,
                icon: view == LibraryView.albums ? Icons.album : Icons.person,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            group.name,
            style: Theme.of(context).textTheme.labelLarge,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            group.subtitle,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: mutedText),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Future<void> _showAddSheet() async {
    final theme = Theme.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Hinzufügen', style: theme.textTheme.titleLarge),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Playlist erstellen'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.go('/playlists?create=1');
              },
            ),
            if (!_settings.localMode)
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('Song hochladen'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _upload();
                },
              ),
            ListTile(
              leading: const Icon(Icons.audiotrack),
              title: const Text('Lokale Songs hinzufügen'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addLocal();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
              title: const Text('Ordner auswählen'),
              onTap: () {
                Navigator.pop(sheetContext);
                _addLocal(folder: true);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// The filter itself, used inline on a wide layout and inside the phone's overlay.
  Widget _filterPanel({
    required Map<String, List<String>> options,
    required Map<String, Set<String>> selected,
    required void Function(String category, String value) onToggle,
    required VoidCallback onReset,
    VoidCallback? onApply,
    bool showReset = true,
  }) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final category in filterKeys)
                    if ((options[category] ?? const []).isNotEmpty) ...[
                      Text(category, style: theme.textTheme.labelLarge),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final value in options[category]!)
                            FilterChip(
                              key: ValueKey('filter-$category-$value'),
                              label: Text(value),
                              selected:
                                  selected[category]?.contains(value) ?? false,
                              onSelected: (_) => onToggle(category, value),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                    ],
                ],
              ),
            ),
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              if (showReset)
                TextButton(
                  onPressed: selected.isEmpty ? null : onReset,
                  child: const Text('Filter zurücksetzen'),
                ),
              if (onApply != null)
                FilledButton(onPressed: onApply, child: const Text('Anwenden')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _loadingState() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            minHeight: 2,
            color: theme.colorScheme.primary,
            backgroundColor: theme.colorScheme.outline,
          ),
          const SizedBox(height: 8),
          Text(
            'Songs werden geladen.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyMessage(String message) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Text(
        message,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _empty(bool searching, bool filtering) {
    final theme = Theme.of(context);
    final emptyLibrary = _tracks.isEmpty && _local.tracks.isEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_note == null) ...[
            Text(
              emptyLibrary
                  ? (_settings.localMode
                        ? 'Die Bibliothek ist noch leer. Füge auf der Startseite lokale Songs hinzu.'
                        : 'Die Bibliothek ist noch leer. Lade einen Song hoch, um sie zu füllen.')
                  : filtering
                  ? 'Keine Songs gefunden.'
                  : 'Keine Songs passen zur Suche.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (!emptyLibrary && filtering) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _resetFilters,
                  child: const Text('Filter zurücksetzen'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
