import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/storage/session_store.dart';
import '../../library/data/library_repository.dart';
import '../../library/data/local_library.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../playlists/domain/playlist.dart';
import '../data/queue_repository.dart';
import '../domain/player.dart';
import '../domain/queue.dart';

/// The queue as a person sees it: what is playing, what comes next, what was played, and the
/// order that can be changed — with a field on top that finds a song without leaving the page.
///
/// One widget for both shapes, because the only difference is the space the parent gives it:
/// inside the app it is the side panel on the right, on a phone it is the drop-up over the page.
/// Nothing here touches the audio — opening the queue only reads the list, so a song keeps
/// playing and closing the panel changes nothing.
///
/// The rows are the shared queue, and a row is a row whatever filled it: a song the server has,
/// or a song on this device. So the same rows move the same way in both modes, and only where a
/// change is written differs — the server, or the store on this device.
class QueuePanel extends StatefulWidget {
  const QueuePanel({
    super.key,
    required this.queues,
    required this.playlists,
    required this.library,
    required this.queue,
    required this.player,
    required this.session,
    this.localMode = false,
    this.localLibrary,
    this.phone = false,
    this.onClose,
  });

  final QueueRepository queues;
  final PlaylistRepository playlists;

  /// Where the songs the search offers come from when no playlist is playing.
  final LibraryRepository library;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;

  /// Without a server the queue is the one stored on this device, and the playlists the menu can
  /// choose are the ones stored here too.
  final bool localMode;

  /// Null in a test that does not care about local mode; the songs on the device then stay in
  /// memory, as the pages that pass one do.
  final LocalLibrary? localLibrary;

  /// Which shape the parent gave this space. A row is taken out by swiping it left in the narrow
  /// shape and by the menu in the wide one, and that is the only difference between the two.
  final bool phone;

  /// What closing means here: the panel is taken out of the frame it was drawn in. Either way the
  /// person is back at the view they came from and the audio runs on.
  final VoidCallback? onClose;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  String? _note;
  bool _busy = false;

  // The field at the top of the panel. A drop-up that only shows the queue makes a song that is
  // not in it reachable only by leaving the page; this is the same search the start page has,
  // in the place the queue is open.
  final TextEditingController _query = TextEditingController();

  /// What the field looks through. Read once when the panel opens: the six under the finger must
  /// not change because the list behind them did.
  List<QueueEntry> _pool = [];

  /// The six an empty field offers: songs of the list that is playing, otherwise of the library.
  List<QueueEntry> _top = [];

  // The playlists the menu can add a song to. A queue row is a reference to a library song, so
  // adding one is the documented POST /api/playlists/{id}/songs; on a device without a server
  // they are the playlists stored there.
  List<Playlist> _playlists = [];
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    // The player moves on its own when a song ends. Without a listener nothing here would
    // redraw: the panel would still show the song that just finished, and the row that moved
    // into "Zuletzt gespielt" would never appear.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _read();
    // The menu adds to a playlist, and the only playlists that can be chosen are the caller's
    // own — a queue answer does not name them. Without a server the songs are on this device, so
    // there is nothing to list and the field fills from them at once.
    if (widget.localMode) {
      _loadSuggestions();
    } else {
      _loadPlaylists();
    }
  }

  @override
  void dispose() {
    // The player belongs to the whole app, so only this panel's listener is dropped here.
    _changes?.cancel();
    _query.dispose();
    super.dispose();
  }

  /// Which list the queue came from. Neither answer names its source, so only what was passed in
  /// when it was filled is known.
  String? _origin() => widget.localMode ? _local.queueOrigin : widget.queue.filledFrom;

  /// Reads the queue. On the server this is the list another device may have changed since the
  /// last look. On this device there is nothing to fetch: the rows are built from the stored
  /// songs, and the player's list is put in step with them so the row named here is the row that
  /// plays.
  Future<void> _read() async {
    if (widget.localMode) {
      _fillFromLocal();
      await _syncLocal();
      return;
    }

    setState(() => _busy = true);
    try {
      final entries = await widget.queues.read();
      if (!mounted) return;

      // What this device is playing is its own: the server keeps the order, not the slot a
      // device is at, so a refresh must not lose it — a paused song is still the song this
      // device is at. If it is no longer in the list the audio stops with it, so the panel and
      // the audio say the same thing.
      final current = widget.queue.current;

      // A queue answer names no source, so the only thing a refresh can keep is what this panel
      // already knew. Rows it did not see before cannot be told apart.
      final known = {for (final entry in widget.queue.entries) if (entry.manual) entry.trackId};

      var keep = -1;
      for (var i = 0; i < entries.length; i++) {
        if (current != null && entries[i].trackId == current.trackId) keep = i;
        if (known.contains(entries[i].trackId)) entries[i] = entries[i].asManual();
      }

      setState(() {
        // The name the list was filled with is kept, because the answer cannot say it.
        widget.queue.fill(entries, fromName: widget.queue.filledFrom);
        widget.queue.index = keep;
        _busy = false;
      });

      if (current != null && keep < 0) await widget.player.stop();
    } on QueueException catch (error) {
      if (!mounted) return;
      _report(error.message, error.statusCode);
      setState(() => _busy = false);
    }
  }

  Future<void> _loadPlaylists() async {
    try {
      final playlists = await widget.playlists.list();
      if (!mounted) return;
      setState(() => _playlists = playlists);
    } on PlaylistException catch (error) {
      if (!mounted) return;
      _report(error.message, error.statusCode);
    }
    // After the names are here, because a playing playlist is what decides the suggestions.
    await _loadSuggestions();
  }

  /// The songs the field offers: the list the queue was filled from while that list is still the
  /// one playing, otherwise the library. Nothing here touches the queue — a suggestion is played
  /// the same way a row is, by being put into the queue first.
  Future<void> _loadSuggestions() async {
    if (widget.localMode) {
      final origin = _local.queueOrigin;
      for (final playlist in _local.playlists) {
        if (playlist.name == origin) {
          return _offer([for (final track in playlist.songs) QueueEntry.fromLocal(0, track)]);
        }
      }
      return _offer([for (final track in _local.tracks) QueueEntry.fromLocal(0, track)]);
    }

    try {
      final origin = _origin();
      Playlist? playing;
      for (final playlist in _playlists) {
        if (playlist.name == origin) playing = playlist;
      }

      if (playing != null) {
        final songs = (await widget.playlists.get(playing.id)).songs;
        if (!mounted) return;
        return _offer([
          for (final song in songs) QueueEntry(position: 0, trackId: song.trackId, title: song.title),
        ]);
      }

      final tracks = await widget.library.list();
      if (!mounted) return;
      _offer([for (final track in tracks) QueueEntry(position: 0, trackId: track.id, title: track.title)]);
    } catch (_) {
      // A suggestion that cannot be read is not a queue that cannot be read: the queue reports
      // its own errors, and the panel stays usable without anything to suggest.
    }
  }

  void _offer(List<QueueEntry> pool) {
    setState(() {
      _pool = pool..shuffle();
      _top = _pool.take(6).toList();
    });
  }

  /// What the field shows: six songs while nothing is typed, otherwise every song the pool has
  /// that matches what was typed.
  List<QueueEntry> _suggestions() {
    final query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return _top;
    return [for (final entry in _pool) if (entry.title.toLowerCase().contains(query)) entry];
  }

  /// Only a 401 says this token is gone; a 429 or a 400 is not a lost login. When the app does
  /// drop it, the guard and the panel agree on the same session.
  void _report(String message, [int? statusCode]) {
    if (statusCode == 401) widget.session.clear();
    setState(() => _note = message);
  }

  /// A row is known by its song only when it is not in the list as itself — that is a row from
  /// "Zuletzt gespielt", which has no slot anymore. A row the panel drew is in the list as that
  /// very object, so the same song twice does not make a menu act on the other copy. A row that
  /// is a file on this device is known by that file, because there is no id for it.
  QueueEntry? _rowInList(QueueEntry entry) {
    for (final row in widget.queue.entries) {
      if (identical(row, entry)) return row;
    }

    for (final row in widget.queue.entries) {
      if (entry.local != null) {
        // A stored queue and the stored library are read separately, so the same file is not the
        // same object after a restart: its path is what says it is the same song.
        if (identical(row.local, entry.local) || (entry.local!.path != null && row.local?.path == entry.local!.path)) {
          return row;
        }
      } else if (row.trackId == entry.trackId) {
        return row;
      }
    }
    return null;
  }

  /// The row a song has in the list. A song from "Zuletzt gespielt" is not in the list anymore,
  /// so it is added back before anything can be done with it.
  Future<QueueEntry?> _rowFor(QueueEntry entry) async {
    final row = _rowInList(entry);
    if (row != null) return row;

    final track = entry.local;
    if (track != null) {
      // A song on this device has no id the server could know, so its row can only be in the
      // queue stored here — even when the queue shown on the page is the server's.
      _local.addToQueue(track);
      final row = QueueEntry.fromLocal(_local.queue.length, track, manual: true);
      widget.queue.append(row);
      return row;
    }

    final added = await widget.queues.append(entry.trackId);
    if (!mounted) return null;
    // The request came from a person, so the row is theirs: "Warteschlange leeren" takes it out
    // again, and the panel says so under the title.
    final own = added.asManual();
    widget.queue.append(own);
    return own;
  }

  /// Puts the mirror back in step with the queue stored on this device. A change that only
  /// touches the store has to come through here, or the page keeps showing rows the store no
  /// longer has.
  void _fillFromLocal() {
    widget.queue.fill(
      [
        for (var i = 0; i < _local.queue.length; i++)
          QueueEntry.fromLocal(i + 1, _local.queue[i], manual: _local.handAdded.contains(_local.queue[i])),
      ],
      fromName: _local.queueOrigin,
    );
  }

  /// Puts the player's list in step with the stored queue, so the row shown here is the row that
  /// plays. Only a device queue needs this: the server keeps the order and the player reads it.
  Future<void> _syncLocal() async {
    await widget.player.syncLocalQueue(_local.queue);
    if (!mounted) return;

    // The mirror and the player must name the same row. After a change on the device the index
    // comes from where the player is, because the audio and the page cannot disagree about what
    // is playing.
    final playing = widget.player.localCurrent;
    widget.queue.index = playing == null ? -1 : widget.queue.entries.indexWhere((row) => identical(row.local, playing));
  }

  /// Plays a row. The queue goes on from that song, which is what clicking a row in a queue
  /// means, not just hearing one song once.
  Future<void> _open(QueueEntry entry) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      final row = await _rowFor(entry);
      if (!mounted || row == null) return;

      if (row.local != null) await _syncLocal();
      if (!mounted) return;

      final played = await widget.player.playAt(row);
      if (!mounted) return;

      setState(() {
        _note = played ? null : 'Das Lied ist nicht mehr in der Warteschlange.';
        _busy = false;
      });
    } on QueueException catch (error) {
      if (!mounted) return;
      _report(error.message, error.statusCode);
      setState(() => _busy = false);
    } catch (error) {
      // A song that cannot be opened is not a JSON answer from the server, so the message here
      // is ours.
      if (!mounted) return;
      _report('Das Lied konnte nicht gespielt werden: $error');
      setState(() => _busy = false);
    }
  }

  Future<void> _remove(QueueEntry entry) async {
    if (_busy) return;

    setState(() => _busy = true);

    // The row being removed may be the one that is playing. The mirror moves to the song that
    // takes its slot, so the audio has to move with it; otherwise the removed song is still
    // audible and the next one is skipped when the current one ends.
    // A row that is only in the history has no slot, so it is added back before it can be
    // taken out. The mirror changes before anything is written, because a row dismissed by a
    // swipe must be gone from the widget tree at once; a failed write then only shows as the note.
    final row = _rowInList(entry) ?? await _rowFor(entry);
    if (!mounted || row == null) return;

    final wasPlaying = identical(row, widget.queue.current);
    widget.queue.removeAt(row.position);

    if (widget.localMode) {
      _local.removeFromQueue(row.position - 1);

      // The row that is audible stops with it, as the player already does for a device queue, and
      // the page says the same as the audio.
      await _syncLocal();
      if (!mounted) return;

      setState(() {
        _note = 'Position ${row.position} entfernt.';
        _busy = false;
      });
      return;
    }

    try {
      await widget.queues.remove(row.position);
      if (!mounted) return;

      setState(() {
        _note = 'Position ${row.position} entfernt.';
        _busy = false;
      });

      if (wasPlaying && widget.player.playing) {
        await widget.player.stop();
        if (!mounted) return;
        await widget.player.playCurrent();
        if (!mounted) return;
        setState(() => _busy = false);
      }
    } on QueueException catch (error) {
      if (!mounted) return;
      _report(error.message, error.statusCode);
      setState(() => _busy = false);
    }
  }

  /// "Warteschlange leeren" takes out only the songs the person put there themselves. The song
  /// being listened to stays, and the songs of the list being played stay, because the list
  /// should not stop in the middle.
  Future<void> _clearOwn() async {
    if (_busy) return;

    final own = [
      for (final entry in widget.queue.entries)
        if (entry.manual && entry != widget.queue.current) entry,
    ];

    if (own.isEmpty) {
      setState(() => _note = 'Es sind keine eigenen Songs in der Warteschlange.');
      return;
    }

    setState(() => _busy = true);

    if (widget.localMode) {
      // Back to front, as on the server: a removal takes the rows after it up one slot, so the
      // numbers of the rows that still have to go would change.
      for (final entry in own.reversed) {
        _local.removeFromQueue(entry.position - 1);
      }

      // Only the store was written, so the rows have to be built again from it.
      _fillFromLocal();
      await _syncLocal();
      if (!mounted) return;

      setState(() {
        _note = 'Eigene Songs entfernt.';
        _busy = false;
      });
      return;
    }

    try {
      // From the back to the front: the server renumbers what follows a removal, so removing a
      // front row first would move the numbers under the rows that still have to go.
      for (final entry in own.reversed) {
        await widget.queues.remove(entry.position);
        if (!mounted) return;
        widget.queue.removeAt(entry.position);
      }

      setState(() {
        _note = 'Eigene Songs entfernt.';
        _busy = false;
      });
    } on QueueException catch (error) {
      if (!mounted) return;
      _report(error.message, error.statusCode);
      setState(() => _busy = false);
    }
  }

  Future<void> _addToPlaylist(QueueEntry entry, int choice) async {
    if (_busy) return;

    setState(() => _busy = true);

    if (widget.localMode) {
      final track = entry.local;
      if (track == null || choice < 0 || choice >= _local.playlists.length) return;
      final playlist = _local.playlists[choice];

      _local.addToPlaylist(playlist, track);
      if (!mounted) return;

      // A playlist on this device does not number its songs, so there is no position to say.
      setState(() {
        _note = 'Song zur Playlist „${playlist.name}“ hinzugefügt.';
        _busy = false;
      });
      return;
    }

    if (choice < 0 || choice >= _playlists.length) return;

    try {
      final song = await widget.playlists.addSong(_playlists[choice].id, entry.trackId);
      if (!mounted) return;

      // The action keeps its name: what the menu said is what happened, with the position the
      // server answered with.
      setState(() {
        _note = 'Song an Position ${song.position} zur Playlist hinzugefügt.';
        _busy = false;
      });
    } on PlaylistException catch (error) {
      if (!mounted) return;
      _report(error.message, error.statusCode);
      setState(() => _busy = false);
    }
  }

  /// "Als Nächstes abspielen" puts a row directly behind the song that is playing, without
  /// starting it. With nothing playing, that row is the next song, so it is played.
  Future<void> _playNext(QueueEntry entry) async {
    if (_busy) return;

    setState(() => _busy = true);

    final row = await _rowFor(entry);
    if (!mounted || row == null) return;

    final current = widget.queue.index;

    if (current < 0) {
      if (row.local != null) await _syncLocal();
      if (!mounted) return;
      await widget.player.playAt(row);
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }

    // The row that is playing cannot be put behind itself, and a slot the panel does not have is
    // not a move. Saying it will be played next would be a claim the panel did not do.
    final at = widget.queue.entries.indexOf(row);
    if (at == current || !await _moveRow(at + 1, current + 2)) {
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }

    if (!mounted) return;
    setState(() {
      _note = 'Das Lied wird als nächstes gespielt.';
      _busy = false;
    });
  }

  /// Moves one row to another slot. On the server only the mirror can be changed, because the
  /// queue has no reorder endpoint (api-docs.md, Upcoming), so this order exists on this device
  /// only and a new read would answer with the server order. Upgrade: the PUT that the playlist
  /// reorder documents. On a device the stored order is what changes, so it stays after a restart.
  Future<bool> _moveRow(int from, int to) async {
    if (from == to) return false;
    if (!widget.queue.move(from, to)) return false;

    if (widget.localMode) {
      _local.move(from, to);
      await _syncLocal();
      if (!mounted) return true;
    }

    return true;
  }

  Future<void> _move(int fromPosition, int toPosition) async {
    if (_busy) return;
    if (fromPosition == toPosition) return; // a row dropped on itself is not a move

    if (!await _moveRow(fromPosition, toPosition)) return;
    if (!mounted) return;

    setState(() => _note = 'Das Lied ist jetzt an Position $toPosition.');
  }

  /// The rows that are not playing. Songs the person put in the queue themselves and songs that
  /// came from a list are shown apart, because that is the difference the story asks for.
  List<QueueEntry> _upcoming({bool own = false}) => [
    for (final entry in widget.queue.entries)
      if (entry != widget.queue.current && entry.manual == own) entry,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: TabBar(
                  tabs: [
                    Tab(icon: Tooltip(message: 'Warteschlange', child: Icon(Icons.queue_music))),
                    Tab(icon: Tooltip(message: 'Zuletzt gespielt', child: Icon(Icons.history))),
                  ],
                ),
              ),
              IconButton(tooltip: 'Warteschlange schließen', icon: const Icon(Icons.close), onPressed: widget.onClose),
            ],
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
              child: Text(_note!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
            ),
          Expanded(child: TabBarView(children: [_queueTab(widget.phone), _historyTab()])),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: IconButton(
                tooltip: 'Warteschlange leeren',
                onPressed: _busy ? null : _clearOwn,
                icon: const Icon(Icons.playlist_remove),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _queueTab(bool phone) {
    final current = widget.queue.current;
    final own = _upcoming(own: true);
    final fromList = _upcoming();
    final suggestions = _suggestions();

    // The field belongs to this tab: it narrows the songs of the queue, and the history is not a
    // list it could search. It stays on top while the rows scroll under it.
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: TextField(
            controller: _query,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(hintText: 'Song suchen', prefixIcon: Icon(Icons.search), isDense: true),
          ),
        ),
        // One list, so the six songs and the queue scroll together: a drop-up has no room for three
        // scroll areas, and a row can still be dropped on any other row.
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
            children: [
              if (suggestions.isNotEmpty) ...[
                _section(_query.text.trim().isEmpty ? 'Vorschläge' : 'Suchergebnisse'),
                for (final entry in suggestions) _suggestion(entry),
              ],
              if (widget.queue.isEmpty)
                _empty()
              else ...[
                if (current != null) ...[
                  _section('Läuft gerade'),
                  _row(current, phone: phone),
                ],
                if (own.isNotEmpty) ...[
                  _section('Als Nächstes in der Warteschlange'),
                  for (final entry in own) _row(entry, phone: phone),
                ],
                if (fromList.isNotEmpty) ...[
                  _section('Als Nächstes aus: ${_origin() ?? 'der Warteschlange'}'),
                  for (final entry in fromList) _row(entry, phone: phone),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// One song the field offers. A tap does what a tap on a queue row does: the song goes into the
  /// queue and starts, so what the panel shows is what is audible.
  Widget _suggestion(QueueEntry entry) {
    final theme = Theme.of(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _busy ? null : () => _open(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.music_note, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
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

  Widget _historyTab() {
    if (widget.queue.history.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Text(
          'Noch nichts gespielt. Sobald ein Lied zu Ende ist, erscheint es hier.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }

    // Newest first, which is what "zuletzt" means.
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      children: [for (final entry in widget.queue.history) _row(entry)],
    );
  }

  /// An empty queue says what would fill it. The field above is where a song is found, so this is
  /// the sentence and not a button that leaves the page.
  Widget _empty() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Füge Songs zur Warteschlange hinzu', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          Text(
            'Such oben nach einem Lied, oder öffne eine Playlist.',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }

  /// The row that is playing, highlighted, because it is the one thing on this page that is
  /// happening now.
  ///
  /// One row in a list. Its cover is replaced by the play symbol while the pointer is on it,
  /// and a row another row is being dropped on is marked, so the slot the move would land in can
  /// be seen before the mouse or the finger is let go.
  Widget _row(QueueEntry entry, {bool phone = false}) {
    // The row is built inside the drag builder, because that is what shows the drop marker. The
    // swipe is what the narrow shape adds: rows that have room for the grip are taken out through
    // the menu, which works in both shapes.
    Widget row(bool dropOn) {
      Widget content = _content(entry, dropOn: dropOn);

      if (phone) {
        content = Dismissible(
          // Keyed by the row itself. A key by the song would collide when the same song is in
          // the queue twice (which the server allows), and a key by the slot is reused by
          // another row after a removal renumbers the rows.
          key: ValueKey(entry),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            color: Theme.of(context).colorScheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: const Icon(Icons.delete_outline),
          ),
          onDismissed: (_) => _remove(entry),
          child: content,
        );
      }

      return content;
    }

    // Only a row of the list can be dropped on: a row of the history has no slot, so a drop on
    // it would move the song to a number the panel does not have.
    if (!widget.queue.entries.contains(entry)) return row(false);

    return DragTarget<int>(
      onAcceptWithDetails: (details) => _move(details.data, entry.position),
      builder: (context, candidate, rejected) => row(candidate.isNotEmpty),
    );
  }

  /// A row, whether it is the one that is playing or one that comes next. The current row is the
  /// highlighted one, because it is the only thing on this page that is happening now.
  ///
  /// shortcut: the queue answer has no cover and no artist (api-docs.md), so the tile is the
  /// placeholder the start page already uses and the line under the title says what the answer
  /// does have. Upgrade: cover and artist when the library rows carry them.
  Widget _content(QueueEntry entry, {bool dropOn = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = entry == widget.queue.current;
    final inList = widget.queue.entries.contains(entry);

    return InkWell(
      onTap: _busy ? null : () => _open(entry),
      child: Container(
        decoration: current
            ? BoxDecoration(
                color: scheme.surfaceContainer,
                border: Border.all(color: scheme.primary),
                borderRadius: BorderRadius.circular(10),
              )
            : (dropOn ? BoxDecoration(border: Border.all(color: scheme.primary)) : null),
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
        child: Row(
          children: [
            _cover(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title, style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    // A row of the history has no list it came from, because what was played is
                    // not a list that is still being played.
                    current
                        ? 'Läuft gerade · Position ${entry.position}'
                        : (inList
                            ? (entry.manual ? 'deine Warteschlange' : (_origin() ?? 'die Warteschlange'))
                            : 'Zuletzt gespielt'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: current ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            // The grip is the handle: hold it and move the row. On a phone that is the long
            // press, on a desktop a press with the mouse. A song from the history is not part
            // of the order, so it has no handle.
            if (inList) LongPressDraggable<int>(data: entry.position, feedback: _feedback(), child: const Icon(Icons.drag_handle, size: 20)),
            _menu(entry),
          ],
        ),
      ),
    );
  }

  Widget _feedback() => const Icon(Icons.drag_handle, color: Colors.white);

  Widget _menu(QueueEntry entry) {
    // The value is the place in the list of the caller's playlists — the same shape in both
    // modes, because a playlist on a device has no id.
    final names = widget.localMode ? _local.playlists.map((playlist) => playlist.name) : _playlists.map((playlist) => playlist.name);
    final choices = [for (var i = 0; i < names.length; i++) ('playlist:$i', names.elementAt(i))];

    return PopupMenuButton<String>(
      tooltip: 'Lied',
      onSelected: (value) => _choose(entry, value),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'remove', child: Text('Aus Warteschlange entfernen')),
        const PopupMenuItem(value: 'next', child: Text('Als Nächstes abspielen')),
        // Adding to a playlist needs one that belongs to the caller, so the names are the choice
        // here and the line above says what picking one of them does.
        const PopupMenuItem(enabled: false, child: Text('Zur Playlist hinzufügen')),
        if (choices.isEmpty)
          const PopupMenuItem(enabled: false, child: Text('Keine Playlist'))
        else
          for (final choice in choices) PopupMenuItem(value: choice.$1, child: Text(choice.$2)),
      ],
    );
  }

  Future<void> _choose(QueueEntry entry, String value) async {
    if (value == 'remove') {
      await _remove(entry);
      return;
    }
    if (value == 'next') {
      await _playNext(entry);
      return;
    }
    await _addToPlaylist(entry, int.parse(value.split(':').last));
  }

  /// The placeholder a cover would be: the app draws covers this way on the start page, because
  /// the library answer has no picture.
  Widget _cover() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary.withValues(alpha: 0.35), scheme.surface],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.audio_file, size: 18, color: scheme.onSurfaceVariant),
    );
  }
}
