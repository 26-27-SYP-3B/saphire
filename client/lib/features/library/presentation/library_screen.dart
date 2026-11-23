import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../../core/utils/audio_format.dart';
import '../../../core/utils/pick_audio.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../playlists/domain/playlist.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/player.dart';
import '../../player/domain/queue.dart';
import '../../upload/data/upload_repository.dart';
import '../../upload/domain/track.dart';
import '../data/library_repository.dart';
import '../data/local_library.dart';
import '../domain/local_track.dart';

/// The three the list can be ordered by. There is nothing else to order by.
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
final fileExtensions = [for (final extension in audioExtensions) extension.substring(1)];

bool looksLikeFileName(String title) {
  final dot = title.lastIndexOf('.');
  return dot > 0 && fileExtensions.contains(title.substring(dot + 1).toLowerCase());
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
/// because the server can only know it for MPEG Layer III (see server/metadata.go).
String durationOf(Track track) {
  if (track.durationMs <= 0) return unknownValue;

  final seconds = track.durationMs ~/ 1000;
  final minutes = seconds ~/ 60;
  return '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// One row of the list: a song from the server or a file on this device. Both are songs
/// the user can play, so they share one list instead of two sections.
class _Entry {
  _Entry.server(Track this.track, this.id) : local = null;
  _Entry.local(LocalTrack this.local, this.id) : track = null;

  final Track? track;
  final LocalTrack? local;

  /// The server id, or a negative one for a song on this device. No two rows share it, so
  /// the order cannot change between rebuilds where the sort keys are equal.
  final int id;

  String get title => track?.title ?? local!.title;

  /// A local file's tags are not read, so the row does not guess an artist from its name.
  String get artist => track == null ? '' : artistOf(track!);

  String get album => track?.album ?? '';

  String get genre => track?.genre ?? '';

  /// 0 where the file names no year, which is every song on this device.
  int get year => track?.year ?? 0;

  String get duration => track == null ? unknownValue : durationOf(track!);

  int get uploadedAt => track?.uploadedAt ?? 0;
}

/// The library: the songs the server has, filtered and sorted, with the same actions the rest
/// of the app uses — play, add to a playlist, add to the queue, upload a new song. It draws
/// the app's frame through AppShell, so it is the same page shape as the start page.
///
/// The songs on this device are in the same list, because to the user they are the same
/// kind of thing: a song that can be played. There is no server call for them, so the page
/// also works in local mode, where there is no session and nothing to upload.
///
/// Playing goes through the shared queue rather than through a second player: a song opened
/// here and a song opened from a playlist play exactly the same way, and the bar at the
/// bottom shows the same song as the queue in the bar.
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
    this.settings,
    this.localLibrary,
    this.initialTrackId,
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

  /// Null in a test that does not care about local mode: the stores then stay in memory.
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;

  /// A song a link named. The list opens and plays that song once it has been read, so a shared
  /// `/library?track=<id>` address is the same as tapping the row. Null when the page was opened
  /// without a link.
  final int? initialTrackId;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _search = TextEditingController();

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  String _sort = sortKeys.first;
  List<Track> _tracks = [];
  List<Playlist> _playlists = [];

  /// The picked values per category. A category with several values matches songs that have
  /// any of them; two categories must both match. Empty means no filter, not "nothing".
  final Map<String, Set<String>> _filters = {};

  /// Whether the wide layout shows the filter panel below the sort. On a phone the panel is
  /// an overlay instead, so this stays false there.
  bool _filtersOpen = false;

  // What a request answered: an error, or nothing when all is well.
  String? _note;

  // Reading the list and sending a batch are two different things. One flag for both would
  // make the button say "Wird hochgeladen…" while nothing is being uploaded, and a batch
  // could be sent into a list that is still on its way.
  bool _loading = false;
  // Choosing the files and sending them are two phases as well: while the picker is open
  // nothing has been sent yet, so the label cannot claim it is.
  bool _picking = false;
  bool _uploading = false;
  bool _busy = false;

  // What the message is about. Only a failed read can be retried here; a file the server
  // refused has to be chosen again, so its message must not offer a retry. The flag belongs
  // to the message, so it is set wherever the message is set.
  bool _noteIsReadError = false;

  // The link is answered once: a later read of the list must not start the song again.
  bool _openedLink = false;

  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    // The bar and the marked row agree on what is current, so this page listens to the
    // player: a song that ends on its own has no tap behind it, and a page that only
    // rebuilt on a tap would still show the row of the song that just finished.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // Both lists are on the server. Local mode has no server and no session, so neither
    // read is sent there; the songs on this device are already in the store.
    if (!_settings.localMode) {
      _load();
      // The names the menu offers come from the server, so they are read with the library. A
      // page that guesses them would show playlists that are not there.
      _loadPlaylists();
    } else if (widget.initialTrackId != null) {
      // A link names a song in the server library; without a server it cannot be opened, and
      // saying so is better than silently opening the device library.
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
    // A second read while one is on its way would let the earlier answer overwrite the
    // later one, so the retry cannot be started twice.
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
      if (mounted) setState(() => _note = 'Das verlinkte Lied ist nicht in der Bibliothek.');
      return;
    }
    await _play(linked);
    // A failed queue call or a refused token must not consume the link for good: a later read
    // (the retry on the page) tries the song again instead of silently forgetting it.
    if (widget.queue.current?.trackId != linked.id) _openedLink = false;
  }

  /// The names the menu can offer. A page that has not read them shows only the queue, and
  /// the first playlist is created when it is picked, because there is no other way to get
  /// one here.
  Future<void> _loadPlaylists() async {
    try {
      final playlists = await widget.playlists.list();
      if (mounted) setState(() => _playlists = playlists);
    } on PlaylistException catch (error) {
      // A note about a link that could not be opened is the more specific answer; a failed
      // playlist read must not replace it.
      if (mounted && _note == null) {
        setState(() {
          _note = error.message;
          _noteIsReadError = false;
        });
      }
    }
  }

  Future<void> _upload() async {
    // The button stays disabled for the whole batch, so a second click cannot send the same
    // files again. A picker that fails must release it too.
    if (_picking) return;
    setState(() => _picking = true);

    final List<PickedAudio>? picked;
    try {
      picked = await widget.pickAudio();
    } catch (error) {
      // The picker itself failing is not a file the server refused, so the row above cannot
      // name a file. The message says what the user can do next.
      if (mounted) {
        setState(() {
          _note = 'Die Dateien konnten nicht gelesen werden. Versuch es erneut.';
          _noteIsReadError = false;
        });
      }
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }

    if (picked == null) return;

    // Only now is a file actually on its way, so only now can the button say so.
    setState(() => _uploading = true);
    try {
      for (final file in picked) {
        try {
          // The server answers with the row it stored, so the song is in the library here
          // without reading the list again.
          final track = await widget.uploads.upload(filename: file.name, bytes: file.bytes);
          if (!mounted) return;
          setState(() => _tracks.add(track));
        } on UploadException catch (error) {
          // A file the server refused is not added. In a batch the message has to say which
          // file it is about, and a later success must not hide it. This message is not about
          // a read, so it must not get the retry that belongs to one.
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
  /// page starts a playlist. The player only ever reads a queue, so a song opened here and a
  /// song opened from a playlist play the same way.
  Future<void> _play(Track track) => _control(() async {
    widget.queue.fill(await widget.queues.fill(QueueSource.track(track.id)));
    await widget.player.playCurrent();
  });

  /// A song on this device plays straight from the file: no queue call and no token, so it
  /// works with no server and no session.
  Future<void> _playLocal(LocalTrack track) => _control(() => widget.player.playLocal(track));

  Future<void> _addToQueue(Track track) => _control(() async {
    final entry = await widget.queues.append(track.id);
    // A row the person added themselves, which is what "Warteschlange leeren" takes out again.
    if (mounted) widget.queue.append(entry.asManual());
  });

  Future<void> _addToPlaylist(Track track, int playlistId) => _control(() async {
    if (playlistId == 0) {
      // Nothing exists yet, so the menu's first entry creates the playlist it names. The id
      // is taken from the answer, not assumed.
      final created = await widget.playlists.create('Meine Playlist');
      if (!mounted) return;
      setState(() => _playlists = [created]);
      await widget.playlists.addSong(created.id, track.id);
      return;
    }
    await widget.playlists.addSong(playlistId, track.id);
  });

  /// Every song, server and device, before search and filter. The filter offers its values
  /// from this list, so a picked value cannot look at a list that is already narrowed by it.
  List<_Entry> _entries() => [
    for (final track in _tracks) _Entry.server(track, track.id),
    for (var index = 0; index < _local.tracks.length; index++)
      _Entry.local(_local.tracks[index], -index - 1),
  ];

  /// What a song says for one filter category. A missing value is "Unbekannt", which is a
  /// filter of its own, so a song without a genre is not hidden from every genre filter.
  String _filterValue(_Entry entry, String category) => switch (category) {
    'Interpret' => entry.artist.isEmpty ? unknownFilter : entry.artist,
    'Album' => entry.album.isEmpty ? unknownFilter : entry.album,
    'Genre' => entry.genre.isEmpty ? unknownFilter : entry.genre,
    _ => entry.year == 0 ? unknownFilter : '${entry.year}',
  };

  /// The values each category offers, read from every song in the list. Ordering is what a
  /// reader expects: names by name, years newest first, and "Unbekannt" at the end of a year
  /// list because it is not a year.
  Map<String, List<String>> _filterOptions() {
    final entries = _entries();
    return {
      for (final category in filterKeys)
        category: ({
          for (final entry in entries) _filterValue(entry, category),
        }.toList()..sort((a, b) {
          if (category != 'Erscheinungsjahr') return a.toLowerCase().compareTo(b.toLowerCase());
          if (a == unknownFilter) return 1;
          if (b == unknownFilter) return -1;
          return int.parse(b).compareTo(int.parse(a));
        })),
    };
  }

  bool _matchesFilters(_Entry entry) {
    for (final category in filterKeys) {
      final chosen = _filters[category];
      if (chosen == null || chosen.isEmpty) continue;
      if (!chosen.contains(_filterValue(entry, category))) return false;
    }
    return true;
  }

  void _toggleFilter(Map<String, Set<String>> filters, String category, String value) {
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

  /// Whether the window has room for the filter panel below the sort. A larger text scale
  /// makes every row taller, so the window has to grow with it.
  bool _inlineFilters(BuildContext context) {
    final room = MediaQuery.sizeOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return room.width >= 700 && room.height >= filterPanelMinHeight * textScale;
  }

  /// Opens the filter. A phone gets it as an overlay from below (with "Anwenden", because the
  /// list is behind it); a wide layout gets it inline below the sort and applies on every tap,
  /// so the list narrows while the filter is still open.
  Future<void> _openFilters() async {
    final options = _filterOptions();

    // The panel needs room below the list controls; a phone in landscape is wide but has no
    // height for it, so it gets the overlay too.
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
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: _filterPanel(
            options: options,
            selected: picked,
            onToggle: (category, value) => setSheet(() => _toggleFilter(picked, category, value)),
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

  /// What the page shows now: the rows that match the search and every picked filter, in the
  /// order the sort was picked. The songs on this device are part of the same list, so the
  /// filter applies to both sources.
  List<_Entry> _visible() {
    final query = _search.text.trim().toLowerCase();
    final rows = [
      for (final entry in _entries())
        if ((query.isEmpty ||
                entry.title.toLowerCase().contains(query) ||
                entry.artist.toLowerCase().contains(query)) &&
            _matchesFilters(entry))
          entry,
    ];

    // Names and artists are compared without case, so "ahne" comes before "Zehn" the way a
    // user reads it. What is not available is a dictionary collation, so an umlaut still
    // sorts by its code point, after z.
    //
    // Newest first for the date; the id decides what the date cannot, so the order does not
    // change on every rebuild. A song on this device has no date, so it counts as the
    // oldest and comes last for "Hinzugefügt am". Its artist is unknown, which sorts it to
    // the top for "Interpret" — the dash the row shows is where an artist would be.
    switch (_sort) {
      case 'Interpret':
        rows.sort((a, b) {
          final byArtist = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
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

  /// The filter itself, used inline on a wide layout and inside the phone's overlay. The
  /// footer's buttons are different because only the phone has to apply a whole selection at
  /// once; the wide layout has already narrowed the list while the chips were tapped.
  Widget _filterPanel({
    required Map<String, List<String>> options,
    required Map<String, Set<String>> selected,
    required void Function(String category, String value) onToggle,
    required VoidCallback onReset,
    VoidCallback? onApply,
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
          // The categories scroll; the buttons stay put, so "Anwenden" is reachable without
          // scrolling past every value.
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
                              selected: selected[category]?.contains(value) ?? false,
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
              TextButton(
                onPressed: selected.isEmpty ? null : onReset,
                child: const Text('Filter zurücksetzen'),
              ),
              if (onApply != null) FilledButton(onPressed: onApply, child: const Text('Anwenden')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = _visible();
    final total = _tracks.length + _local.tracks.length;
    final filtering = _filters.isNotEmpty;
    final searching = _search.text.trim().isNotEmpty;
    final filterCount = _filters.values.fold<int>(0, (sum, values) => sum + values.length);
    final inlineFilters = _inlineFilters(context);

    return AppShell(
      selected: '/library',
      player: widget.player,
      queues: widget.queues,
      playlists: widget.playlists,
      library: widget.library,
      session: widget.session,
      localMode: _settings.localMode,
      localLibrary: _local,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Bibliothek', style: theme.textTheme.titleLarge),
                const SizedBox(height: 4),
                // What the page holds right now. While the list is on its way there is
                // nothing to count, and a row that is not shown cannot be counted either, so
                // this line says nothing until something is actually there.
                if (!_loading && total > 0)
                  Text(
                    !filtering && !searching
                        ? '$total Songs'
                        : '${rows.length} von $total Songs passen '
                              '${filtering && searching ? 'zu Suche und Filter' : filtering ? 'zu den Filtern' : 'zur Suche'}',
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                    const SizedBox(width: 16),
                    // One button for the whole page, so uploading works whether the library is
                    // empty or already has songs in it. Its label follows what is actually
                    // happening, and it is not usable while a batch is on its way or while the
                    // list it would add to is still being read. Local mode has no server to
                    // upload to.
                    if (!_settings.localMode)
                      FilledButton(
                        onPressed: _loading || _picking || _uploading ? null : _upload,
                        child: Text(_uploading ? 'Wird hochgeladen…' : 'Song hochladen'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final key in sortKeys) _sortChip(key),
                    OutlinedButton.icon(
                      onPressed: _openFilters,
                      icon: const Icon(Icons.filter_list, size: 18),
                      label: Text(filterCount == 0 ? 'Filter' : 'Filter ($filterCount)'),
                    ),
                  ],
                ),
                // The picked values stay visible above the list, so a narrowed list always
                // says why it is narrow. Each chip can be taken off on its own; the button
                // takes all of them off at once.
                if (_filters.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final category in filterKeys)
                        for (final value in _filters[category] ?? const <String>{})
                          InputChip(
                            label: Text('$category: $value'),
                            onDeleted: () => setState(() => _removeFilter(category, value)),
                            deleteButtonTooltipMessage: 'Filter $category: $value entfernen',
                          ),
                      TextButton(onPressed: _resetFilters, child: const Text('Filter zurücksetzen')),
                    ],
                  ),
                ],
                // A wide layout keeps the filter open below the list controls; the phone puts
                // the same panel in an overlay instead.
                if (_filtersOpen && inlineFilters)
                  _filterPanel(
                    options: _filterOptions(),
                    selected: _filters,
                    onToggle: (category, value) => setState(() => _toggleFilter(_filters, category, value)),
                    onReset: _resetFilters,
                  ),
              ],
            ),
          ),
          // A message about a read is not shown while a new read is on its way: the page
          // would be reporting what an earlier answer said and what it is doing at the same
          // time.
          if (_note != null && !_loading)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Row(
                children: [
                  Expanded(child: Text(_note!, style: TextStyle(color: scheme.error))),
                  // Only a read can be started again from here.
                  if (_noteIsReadError)
                    TextButton(onPressed: _load, child: const Text('Erneut versuchen')),
                ],
              ),
            ),
          // While the list is on its way the page says that. It cannot claim what the library
          // holds before it has an answer, and an empty message here read as "there is
          // nothing" while the request was still open.
          Expanded(
            child: _loading
                ? _loadingState()
                : rows.isEmpty
                ? _empty()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    itemCount: rows.length,
                    itemBuilder: (context, index) => _row(rows[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sortChip(String key) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picked = key == _sort;

    // The selected one is shown by color alone, so it is said again for anyone who does not
    // see the fill, and the row is tall enough to be a target, not a line.
    return Semantics(
      button: true,
      selected: picked,
      child: InkWell(
        onTap: () => setState(() => _sort = key),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          decoration: BoxDecoration(
            color: picked ? scheme.primary : scheme.surfaceContainer,
            border: Border.all(color: picked ? scheme.primary : scheme.outline),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            key,
            style: theme.textTheme.labelLarge?.copyWith(color: picked ? scheme.onPrimary : scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// While the list is on its way the page says what it is doing, because it cannot claim
  /// anything about a library it has not read.
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
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    final theme = Theme.of(context);
    final emptyLibrary = _tracks.isEmpty && _local.tracks.isEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Where a message above already says what went wrong, nothing here claims what the
          // library holds — that would be the page lying about an answer it never got.
          if (_note == null) ...[
            Text(
              emptyLibrary
                  ? (_settings.localMode
                        ? 'Die Bibliothek ist noch leer. Füge auf der Startseite lokale Songs hinzu.'
                        : 'Die Bibliothek ist noch leer. Lade einen Song hoch, um sie zu füllen.')
                  : _filters.isNotEmpty
                  ? 'Keine Songs gefunden.'
                  : 'Keine Songs passen zur Suche.',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            // A filter the user set can hide every song, and the list behind this message is
            // not the place to take it off again.
            if (!emptyLibrary && _filters.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: _resetFilters, child: const Text('Filter zurücksetzen')),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// One song: its name, what is known about it, and the actions the menu has. The whole
  /// row can be tapped, so playing a song does not need the small icon. A song on this
  /// device says so instead of an artist, and has no server actions.
  Widget _row(_Entry entry) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = entry.track;
    final local = entry.local;
    // The row of the song that is current is the one the bar at the bottom is showing, so
    // both agree on what is current. A local file has no queue slot, so the player's own
    // current song decides there.
    final current = local != null
        ? identical(widget.player.localCurrent, local)
        : widget.queue.current?.trackId == track!.id;
    final artist = entry.artist;

    void play() {
      if (local != null) {
        _playLocal(local);
      } else {
        _play(track!);
      }
    }

    return InkWell(
      onTap: _busy ? null : play,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          // The current song is the one place on this page where the accent marks what is
          // active; nothing else on the page is accent-colored.
          color: current ? scheme.surfaceContainer : null,
          border: Border(
            // Flutter's default border color is black, so an unmarked row has to be said as
            // transparent rather than left out.
            left: BorderSide(color: current ? scheme.primary : Colors.transparent, width: 2),
            bottom: BorderSide(color: scheme.outline),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Abspielen',
              onPressed: _busy ? null : play,
              icon: Icon(Icons.play_arrow, color: current ? scheme.primary : scheme.onSurfaceVariant),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: theme.textTheme.labelLarge?.copyWith(color: current ? scheme.primary : null),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    // What is known about the song: the artist its tags name, or what its own
                    // name says when they do not. A song on this device has no tags to read.
                    // Where nothing is known, the row shows a dash.
                    local != null ? 'Auf diesem Gerät' : (artist.isEmpty ? unknownValue : artist),
                    style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // The length is put at the end of the row, so a list can be read top to bottom
            // without reading every line.
            Text(
              entry.duration,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
            // A local file is not on the server, so it cannot go into a server queue or a
            // server playlist.
            if (track != null)
              PopupMenuButton<String>(
                tooltip: 'Aktionen für ${entry.title}',
                onSelected: (value) {
                  if (value == 'queue') {
                    _addToQueue(track);
                  } else {
                    _addToPlaylist(track, int.parse(value));
                  }
                },
                itemBuilder: (context) => [
                  // Which playlists exist is the playlist page; here the menu can only add to
                  // one that this page has read, or start the first one.
                  if (_playlists.isEmpty)
                    const PopupMenuItem(value: '0', child: Text('Zur neuen Playlist „Meine Playlist“')),
                  for (final playlist in _playlists)
                    PopupMenuItem(value: playlist.id.toString(), child: Text('Zur Playlist „${playlist.name}“')),
                  const PopupMenuItem(value: 'queue', child: Text('Zur Warteschlange hinzufügen')),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
