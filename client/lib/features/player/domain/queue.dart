/// One song in a queue, exactly as the queue endpoints answer it. An entry is a
/// reference to a library song: it has no file of its own, and the title can change
/// under it.
class QueueEntry {
  const QueueEntry({required this.position, required this.trackId, required this.title});

  /// 1-based, as the server numbers the slots. The positions stay contiguous, so a row
  /// can be addressed without knowing what was removed before it.
  final int position;
  final int trackId;
  final String title;

  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    position: (json['position'] as num).toInt(),
    trackId: (json['track_id'] as num).toInt(),
    title: json['title'] as String,
  );

  /// The same song at another slot. The mirror renumbers this way, so a page shows the
  /// numbers the next read from the server would return.
  QueueEntry withPosition(int position) =>
      QueueEntry(position: position, trackId: trackId, title: title);
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

  /// -1 means nothing is current. The server never says which song a device plays.
  int index = -1;

  List<QueueEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  QueueEntry? get current => (index >= 0 && index < _entries.length) ? _entries[index] : null;

  /// Replaces the queue, the way POST /api/queue does: starting a second playlist must
  /// not keep the songs of the first. Nothing becomes current by filling: a queue is an
  /// order, and which song is playing is the device's decision, not the list's.
  void fill(List<QueueEntry> from) {
    _entries
      ..clear()
      ..addAll(from);
    index = -1;
  }

  void append(QueueEntry entry) => _entries.add(entry);

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

  void clear() {
    _entries.clear();
    index = -1;
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
