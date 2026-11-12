import '../../library/domain/local_track.dart';

/// One song in a queue. It is either a reference to a library song, exactly as the queue
/// endpoints answer it, or a song on this device — a queue page shows both the same way, so
/// a row must not care which store it came from. A row has no file of its own, and the title
/// can change under it.
class QueueEntry {
  const QueueEntry({
    required this.position,
    required this.trackId,
    required this.title,
    this.manual = false,
    this.local,
  });

  /// A row that is a file on this device. There is no server id for it, so `trackId` is -1
  /// and `local` is the whole row.
  factory QueueEntry.fromLocal(int position, LocalTrack track, {bool manual = true}) =>
      QueueEntry(position: position, trackId: -1, title: track.title, manual: manual, local: track);

  /// 1-based, as the server numbers the slots. The positions stay contiguous, so a row
  /// can be addressed without knowing what was removed before it.
  final int position;

  /// -1 for a row that is a file on this device.
  final int trackId;
  final String title;

  /// How the row got into the queue: the person put it there themselves, or a list did. The
  /// queue answer names no source, so this is what the mirror keeps, and it is the only thing
  /// a refresh can carry over.
  final bool manual;

  /// The song on this device, null for a song the server has.
  final LocalTrack? local;

  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    position: (json['position'] as num).toInt(),
    trackId: (json['track_id'] as num).toInt(),
    title: json['title'] as String,
  );

  /// The same song at another slot. The mirror renumbers this way, so a page shows the
  /// numbers the next read from the server would return.
  QueueEntry withPosition(int position) =>
      QueueEntry(position: position, trackId: trackId, title: title, manual: manual, local: local);

  QueueEntry asManual() => QueueEntry(position: position, trackId: trackId, title: title, manual: true, local: local);
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

  /// The name of the list this queue was filled from. A queue answer does not name its
  /// source, so the page cannot find it out again; it is what a page passed in when it filled.
  String? filledFrom;

  /// The songs that were played, newest first. What was played is not stored anywhere, so this
  /// is the memory of the device — and it is bounded, because a queue that runs for a day
  /// would otherwise grow without end.
  final List<QueueEntry> history = [];
  static const int historyLimit = 50;

  List<QueueEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;

  QueueEntry? get current => (index >= 0 && index < _entries.length) ? _entries[index] : null;

  /// Replaces the queue, the way POST /api/queue does: starting a second playlist must
  /// not keep the songs of the first. Nothing becomes current by filling: a queue is an
  /// order, and which song is playing is the device's decision, not the list's.
  void fill(List<QueueEntry> from, {String? fromName}) {
    _entries
      ..clear()
      ..addAll(from);
    index = -1;
    filledFrom = fromName ?? filledFrom;
  }

  void append(QueueEntry entry) => _entries.add(entry);

  /// Records a song the player started, newest first. Only a song that was really opened
  /// belongs here — a row the player only pointed at is not something that was played.
  void recordPlayed(QueueEntry entry) {
    history.insert(0, entry);
    if (history.length > historyLimit) history.removeLast();
  }

  /// Moves one 1-based slot to another and renumbers what is in between, the same way a
  /// removal renumbers. Returns false when a slot is outside the mirror or the row is dropped
  /// on itself, because that is not a move. The current row is followed, so pointing at a
  /// row keeps pointing at the same song after the move.
  bool move(int from, int to) {
    if (from < 1 || from > _entries.length || to < 1 || to > _entries.length) return false;
    if (from == to) return false;

    // The current row is named by its object, not by a number that would now be another
    // song's. The object is taken before the row moves, and the index before the renumbering,
    // because renumbering makes new objects. An index outside the mirror is not a row, so nothing
    // is followed and the move still works.
    final current = (index >= 0 && index < _entries.length) ? _entries[index] : null;

    final row = _entries.removeAt(from - 1);
    _entries.insert(to - 1, row);

    if (current != null) index = _entries.indexOf(current);

    for (var i = 0; i < _entries.length; i++) {
      _entries[i] = _entries[i].withPosition(i + 1);
    }

    return true;
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
