import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/session_store.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../playlists/domain/playlist.dart';
import '../data/queue_repository.dart';
import '../domain/player.dart';
import '../domain/queue.dart';

/// The queue as a person sees it: what is playing, what comes next, what was played, and the
/// order that can be changed.
///
/// One widget for both shapes, because the only difference is the space the parent gives it:
/// inside the app it is the side panel on the right, on a phone it is the whole page. Nothing
/// here touches the audio — opening the queue only reads the list, so a song keeps playing and
/// closing the panel changes nothing.
class QueuePanel extends StatefulWidget {
  const QueuePanel({
    super.key,
    required this.queues,
    required this.playlists,
    required this.queue,
    required this.player,
    required this.session,
    this.onClose,
  });

  final QueueRepository queues;
  final PlaylistRepository playlists;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;

  /// What closing means here: the page is popped back on a phone, the panel is closed inside
  /// the app. Either way the person is back at the view they came from and the audio runs on.
  final VoidCallback? onClose;

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  String? _note;
  bool _busy = false;

  // Which row the pointer is on. A row only shows the play symbol in place of its cover while
  // it is hovered, so the row needs to know that.
  int? _hovered;

  // The playlists the menu can add a song to. A queue row is a reference to a library song, so
  // adding one is the documented POST /api/playlists/{id}/songs.
  List<Playlist> _playlists = [];

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
    // The queue lives on the server, so another device may have changed it. Reading it when the
    // panel opens is what makes it show the current list.
    _read();
    // The menu adds to a playlist, and the only playlists that can be chosen are the caller's
    // own — a queue answer does not name them.
    _loadPlaylists();
  }

  @override
  void dispose() {
    // The player belongs to the whole app, so only this panel's listener is dropped here.
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
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
  }

  /// Only a 401 says this token is gone; a 429 or a 400 is not a lost login. When the app does
  /// drop it, the guard and the panel agree on the same session.
  void _report(String message, [int? statusCode]) {
    if (statusCode == 401) widget.session.clear();
    setState(() => _note = message);
  }

  /// The row a song has in the list. A row is known by its song, not by the object: the mirror
  /// renumbers rows, and a renumbered row is another object with the same song.
  QueueEntry? _rowInList(QueueEntry entry) {
    for (final row in widget.queue.entries) {
      if (row.trackId == entry.trackId) return row;
    }
    return null;
  }

  /// The row a song has in the list. A song from "Zuletzt gespielt" is not in the list
  /// anymore, so it is added the way the plain queue feature does before anything can be done
  /// with it.
  Future<QueueEntry> _rowFor(QueueEntry entry) async {
    final row = _rowInList(entry);
    if (row != null) return row;

    final added = await widget.queues.append(entry.trackId);
    if (!mounted) return added;
    widget.queue.append(added);
    return added;
  }

  /// Plays a row. The queue goes on from that song, which is what clicking a row in a queue
  /// means, not just hearing one song once.
  Future<void> _open(QueueEntry entry) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      final row = await _rowFor(entry);
      if (!mounted) return;

      await widget.player.playAt(row.position);
      if (!mounted) return;

      setState(() {
        _note = null;
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
    // taken out. The mirror changes before the server is told, because a row dismissed by a swipe
    // must be gone from the widget tree at once; a failed delete then only shows as the note.
    final row = _rowInList(entry) ?? await _rowFor(entry);
    if (!mounted) return;

    final wasPlaying = widget.queue.entries.indexOf(row) == widget.queue.index;
    widget.queue.removeAt(row.position);
    setState(() => _busy = true);

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

  Future<void> _addToPlaylist(QueueEntry entry, int playlistId) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      final song = await widget.playlists.addSong(playlistId, entry.trackId);
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

    final row = await _rowFor(entry);
    if (!mounted) return;

    final current = widget.queue.index;

    if (current < 0) {
      await widget.player.playAt(row.position);
      if (!mounted) return;
      setState(() => _busy = false);
      return;
    }

    // The row that is playing cannot be put behind itself, and a slot the mirror does not have
    // is not a move. Saying it will be played next would be a claim the panel did not do.
    if (current == widget.queue.entries.indexOf(row) || !widget.queue.move(widget.queue.entries.indexOf(row), current + 1)) {
      setState(() => _busy = false);
      return;
    }

    setState(() {
      _note = 'Das Lied wird als nächstes gespielt.';
      _busy = false;
    });
  }

  /// Moves a row to another slot. shortcut: the queue has no reorder endpoint (api-docs.md,
  /// Upcoming), so this order only exists on this device and a new read would answer with the
  /// server order. Upgrade: the PUT that the playlist reorder documents.
  void _move(int fromPosition, int toPosition) {
    if (_busy) return;
    if (fromPosition == toPosition) return; // a row dropped on itself is not a move
    if (!widget.queue.move(fromPosition - 1, toPosition - 1)) return;

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
      child: LayoutBuilder(builder: (context, constraints) {
        // Below this width the panel is the phone view, where a row is taken out by swiping it
        // left rather than by dragging it.
        final phone = constraints.maxWidth < 520;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: TabBar(tabs: [Tab(text: 'Warteschlange'), Tab(text: 'Zuletzt gespielt')]),
                ),
                IconButton(tooltip: 'Warteschlange schließen', icon: const Icon(Icons.close), onPressed: widget.onClose),
              ],
            ),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                child: Text(_note!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
              ),
            Expanded(child: TabBarView(children: [_queueTab(phone), _historyTab()])),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: FilledButton.tonal(
                onPressed: _busy ? null : _clearOwn,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                child: const Text('Warteschlange leeren'),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _queueTab(bool phone) {
    if (widget.queue.isEmpty) return _empty();

    // Headings and rows are one list here rather than two lists, so a row can be dropped on any
    // other row. Inside a group the rows are in the order the player goes through them.
    final current = widget.queue.current;
    final own = _upcoming(own: true);
    final fromList = _upcoming();

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
      children: [
        if (current != null) ...[
          _section('Läuft gerade'),
          _row(current, phone: phone),
        ],
        if (own.isNotEmpty) ...[
          _section('Als Nächstes in der Warteschlange'),
          for (final entry in own) _row(entry, phone: phone),
        ],
        if (fromList.isNotEmpty) ...[
          _section('Als Nächstes aus: ${widget.queue.filledFrom ?? 'der Warteschlange'}'),
          for (final entry in fromList) _row(entry, phone: phone),
        ],
      ],
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

  Widget _empty() {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Füge Songs zur Warteschlange hinzu', style: theme.textTheme.titleMedium),
          const SizedBox(height: 10),
          FilledButton(
            // The search is on the start page. There is no search endpoint yet, so that is where
            // a song can be found and put in the queue.
            onPressed: () => context.go('/home'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            child: const Text('Songs suchen'),
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
    final hovered = _hovered == entry.position;
    final current = entry == widget.queue.current;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = entry.position),
      onExit: (_) => setState(() => _hovered = null),
      child: InkWell(
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
              // Hovering or tapping a row shows what the row is for: the song starts here and the
              // queue goes on from here.
              hovered ? _playIcon() : _cover(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.title, style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      current
                          ? 'Läuft gerade · Position ${entry.position}'
                          : (entry.manual ? 'deine Warteschlange' : (widget.queue.filledFrom ?? 'die Warteschlange')),
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
              if (widget.queue.entries.contains(entry))
                LongPressDraggable<int>(
                  data: entry.position,
                  feedback: const Icon(Icons.drag_handle, color: Colors.white),
                  child: const Icon(Icons.drag_handle, size: 20),
                ),
              _menu(entry),
            ],
          ),
        ),
      ),
    );
  }

  Widget _menu(QueueEntry entry) {
    return PopupMenuButton<String>(
      tooltip: 'Lied',
      onSelected: (value) => _choose(entry, value),
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'remove', child: Text('Aus Warteschlange entfernen')),
        const PopupMenuItem(value: 'next', child: Text('Als Nächstes abspielen')),
        // Adding to a playlist needs one that belongs to the caller, so the names are the choice
        // here and the line above says what picking one of them does.
        const PopupMenuItem(enabled: false, child: Text('Zur Playlist hinzufügen')),
        if (_playlists.isEmpty)
          const PopupMenuItem(enabled: false, child: Text('Keine Playlist'))
        else
          for (final playlist in _playlists) PopupMenuItem(value: 'playlist:${playlist.id}', child: Text(playlist.name)),
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

  Widget _playIcon() {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(8)),
      child: Icon(Icons.play_arrow, size: 20, color: scheme.onPrimary),
    );
  }
}
