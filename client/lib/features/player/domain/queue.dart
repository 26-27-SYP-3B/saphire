/// One song in a queue, exactly as the queue endpoints answer it. An entry is a
/// reference to a library song: it has no file of its own, and the title can change
/// under it.
class QueueEntry {
  const QueueEntry({required this.position, required this.trackId, required this.title, this.manual = false});

  /// 1-based, as the server numbers the slots. The positions stay contiguous, so a row
  /// can be addressed without knowing what was removed before it.
  final int position;
  final int trackId;
  final String title;

  /// Whether this device put the song in the queue itself or got it from a list. The server
  /// stores only the order and nothing about what filled it, so this is only what the app
  /// remembers from the last fill or append. It is what separates "Als Nächstes in der
  /// Warteschlange" from "Als Nächstes aus: …", and what "Warteschlange leeren" removes.
  final bool manual;

  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    position: (json['position'] as num).toInt(),
    trackId: (json['track_id'] as num).toInt(),
    title: json['title'] as String,
  );

  /// The same song at another slot. The mirror renumbers this way, so a page shows the
  /// numbers the next read from the server would return.
  QueueEntry withPosition(int position) =>
      QueueEntry(position: position, trackId: trackId, title: title, manual: manual);

  /// The same song, known to be one the person put in the queue by hand.
  QueueEntry asManual() => manual
      ? this
      : QueueEntry(position: position, trackId: trackId, title: title, manual: true);
}

/// Where a queue gets its songs. These are the three sources api-docs.md lists. A queue
/// itself knows nothing about its source — that is the point: a plain queue feature
/// later is another source here, not a different queue.
class QueueSource {
  const QueueSource._(this.type, this.id);

  const QueueSource.playlist(int id) : this._('playlist', id);
  const QueueSource.library() : this._('library', 0);
  const QueueSource.track(int id) : this._('track', id);

  final String type;
  final int id;

  bool get needsId => type != 'library';

  /// The body POST /api/queue expects. source_id is only part of it for a source that
  /// names something; sending it for the whole library is refused by the server, so it
  /// must not be sent there.
  Map<String, Object> toJson() => needsId ? {'source': type, 'source_id': id} : {'source': type};

  /// What the source is, in the words a user understands.
  String describe() => switch (type) {
        'playlist' => 'Playlist $id',
        'library' => 'die ganze Bibliothek',
        _ => 'Ein Lied ($id)',
      };
}

/// The player's view of a queue: the songs in order and which one is current. It is
/// filled from a list, never from a source, so a queue that came from a playlist and a
/// queue that came from one song are the same thing here.
///
/// The list itself always comes from the server, because the queue is stored there and
/// another device can change it. What a device is currently playing is not stored on the
/// server — that is device state — so this index is the only thing the mirror owns.
class PlaybackQueue {
  PlaybackQueue([List<QueueEntry> entries = const []]) : _entries = List.of(entries);

  final List<QueueEntry> _entries;

  /// -1 means nothing is current. The server never says which device plays what.
  int index = -1;

  /// What this device last filled the queue from, in the words a section heading needs.
  /// The server does not store a source, so a page can only show what this device was told
  /// when the list was filled.
  String? filledFrom;

  /// The songs this device played, newest first — the "Zuletzt gespielt" list. There is no
  /// history endpoint, so this lives only while the app runs.
  /// shortcut: capped at 50 so a player left open for days does not grow without end.
  /// Upgrade: a store, if the app should remember across restarts.
  final List<QueueEntry> history = [];

  List<QueueEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  QueueEntry? get current => (index >= 0 && index < _entries.length) ? _entries[index] : null;

  /// Replaces the queue, the way POST /api/queue does: starting a second playlist must
  /// not keep the songs of the first. Nothing becomes current by filling: a queue is an
  /// order, and which song is playing is the device's decision, not the list's.
  ///
  /// `fromName` is the list the rows came from. Rows with no list behind them are songs the
  /// person put there by hand, and those are the ones "Warteschlange leeren" removes.
  void fill(List<QueueEntry> from, {String? fromName}) {
    _entries
      ..clear()
      ..addAll([for (final entry in from) fromName == null ? entry.asManual() : entry]);
    index = -1;
    filledFrom = fromName;
  }

  /// Adds one song at the end — the plain queue feature, POST /api/queue/songs. An entry
  /// added this way is always one the person put there themselves.
  void append(QueueEntry entry) => _entries.add(entry.asManual());

  /// Records a song as played, newest first, for the "Zuletzt gespielt" tab. Only a song
  /// this device actually started belongs here, so this is called when playback moves on.
  void recordPlayed(QueueEntry entry) {
    history.insert(0, entry);
    if (history.length > 50) history.removeLast();
  }

  /// Removes one 1-based slot and renumbers the rest. The server does the same, so the
  /// mirror stays the same shape without asking again. Returns false when the mirror is
  /// shorter than the queue the server has — another device can have changed it — so the
  /// page does not report a success it did not have.
  bool removeAt(int position) {
    if (position < 1 || position > _entries.length) return false;

    final at = position - 1;
    final wasCurrent = index == at;
    _entries.removeAt(at);

    // The server renumbers the slots after the removed one, so the mirror does the same:
    // the numbers a page shows are the ones the next read would return.
    for (var i = at; i < _entries.length; i++) {
      _entries[i] = _entries[i].withPosition(i + 1);
    }

    if (wasCurrent) {
      // The current row is gone. The same index now holds the next song; if nothing is
      // left there, the queue is finished.
      index = at < _entries.length ? at : -1;
    } else if (index > at) {
      index -= 1;
    }

    return true;
  }

  /// Moves a row to another slot and renumbers, the way the server would after a move. The
  /// song that is playing is not touched: dragging a row must not change what is audible.
  /// Returns false for a slot the mirror does not have.
  /// shortcut: there is no reorder endpoint (api-docs.md, Upcoming), so this order exists
  /// only on this device and a read would give the server order back. Upgrade: the
  /// documented PUT /api/playlists/{id}/songs/{position} rule, once the queue has one too.
  bool move(int from, int to) {
    if (from < 0 || from >= _entries.length || to < 0 || to >= _entries.length) return false;
    if (from == to) return true;

    final wasCurrent = index == from;
    final entry = _entries.removeAt(from);
    _entries.insert(to, entry);

    for (var i = 0; i < _entries.length; i++) {
      _entries[i] = _entries[i].withPosition(i + 1);
    }

    if (wasCurrent) {
      index = to;
    } else if (index >= 0) {
      // Every row that passed the current one shifts it, and so does every row it passed.
      if (index > from) index -= 1;
      if (index >= to) index += 1;
    }

    return true;
  }

  /// Moves to the next song and returns what should play next, or null when the queue is
  /// finished — a player needs that to stop instead of waiting for a song that is not
  /// there. While nothing is current, the first call takes the first song: that is what
  /// pressing play on a filled queue means.
  QueueEntry? advance() {
    if (_entries.isEmpty) return null;

    if (index < 0) {
      index = 0;
      return _entries[0];
    }
    if (index >= _entries.length) return null;

    index += 1;
    return index < _entries.length ? _entries[index] : null;
  }
}
