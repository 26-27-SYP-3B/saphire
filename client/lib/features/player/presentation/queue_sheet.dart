import 'dart:async';

import 'package:flutter/material.dart';

import '../../library/data/library_repository.dart';
import '../../library/data/local_library.dart';
import '../../library/domain/local_track.dart';
import '../../upload/domain/track.dart';
import '../data/queue_repository.dart';
import '../domain/player.dart';

/// Opens the queue over the page it belongs to. The bar is the way in, so the queue has no
/// page of its own: an order belongs to the player, not to the navigation.
Future<void> showQueueSheet(
  BuildContext context, {
  required QueueRepository queues,
  required LibraryRepository library,
  required QueuePlayer player,
  required bool localMode,
  LocalLibrary? localLibrary,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.9,
        child: QueueSheet(
          queues: queues,
          library: library,
          player: player,
          localMode: localMode,
          localLibrary: localLibrary,
        ),
      ),
    );

/// The queue: what is lined up, which song is current, and what happens when a song ends —
/// plus the second tab that puts any song from the library into it.
///
/// Nothing here knows where the songs came from. The list was filled from a source — a
/// playlist, one song, the library — and after that a queue is just an order.
class QueueSheet extends StatefulWidget {
  const QueueSheet({
    super.key,
    required this.queues,
    required this.library,
    required this.player,
    required this.localMode,
    this.localLibrary,
  });

  final QueueRepository queues;
  final LibraryRepository library;
  final QueuePlayer player;
  final bool localMode;

  /// Null in a test that does not pass one; the songs on the device then stay in memory.
  final LocalLibrary? localLibrary;

  @override
  State<QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<QueueSheet> {
  String? _note;
  bool _busy = false;
  StreamSubscription<void>? _changes;

  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  // The songs the add tab offers. The server keeps the library, so it is read once when the
  // sheet opens; the songs on this device are already in the store.
  List<Track> _songs = const [];
  bool _loadingSongs = false;
  String? _songsNote;

  @override
  void initState() {
    super.initState();
    // The player moves on its own when a song ends. Without a listener the sheet would
    // only rebuild when the user did something, and it would keep showing the song that
    // just finished.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // The queue lives on the server, so another device may have changed it since the last
    // look. Reading it again is what makes the sheet show the current list.
    _read();
    _loadSongs();
  }

  @override
  void dispose() {
    // The player belongs to the whole app, so only this sheet's listener is dropped here.
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _loadSongs() async {
    if (widget.localMode) return;

    setState(() => _loadingSongs = true);
    try {
      final songs = await widget.library.list();
      if (!mounted) return;
      setState(() {
        _songs = songs;
        _loadingSongs = false;
      });
    } on LibraryException catch (error) {
      if (!mounted) return;
      setState(() {
        _songsNote = error.message;
        _loadingSongs = false;
      });
    }
  }

  Future<void> _read() async {
    // The local queue is on the device. There is nothing to fetch and no token to send.
    if (widget.localMode) {
      setState(() {
        _note = _local.queue.isEmpty
            ? 'Die Warteschlange ist leer. Nutze „Lieder hinzufügen“ oder starte eine Playlist.'
            : null;
      });
      return;
    }

    setState(() => _busy = true);
    try {
      final entries = await widget.queues.read();
      if (!mounted) return;

      // What this device is playing is its own: the server keeps the order, not the slot a
      // device is at. A refresh must not lose that. If the song is still in the list the
      // sheet keeps pointing at it; if it is gone, the audio stops with it, so the sheet and
      // the audio say the same thing.
      final current = widget.player.playing ? widget.player.queue.current : null;
      var keep = -1;
      for (var i = 0; i < entries.length; i++) {
        if (current != null && entries[i].trackId == current.trackId) {
          keep = i;
          break;
        }
      }

      setState(() {
        widget.player.queue.fill(entries);
        widget.player.queue.index = keep;
        _note = entries.isEmpty ? 'Die Warteschlange ist leer. Starte eine Playlist oder füge ein Lied hinzu.' : null;
        _busy = false;
      });

      if (current != null && keep < 0) await widget.player.stop();
    } on QueueException catch (error) {
      if (!mounted) return;
      // Only a 401 says this token is gone; a 429 or a 400 is not a lost login. When the
      // app does drop it, the guard and the sheet agree on the same session.
      if (error.statusCode == 401) widget.player.session.clear();
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _play() async {
    if (widget.localMode) {
      if (_local.queue.isEmpty) {
        setState(() {
          _note = 'Die Warteschlange ist leer, es gibt nichts zu spielen.';
          _busy = false;
        });
        return;
      }

      setState(() => _busy = true);
      try {
        // The stored queue may have grown since this song was opened, so the player gets
        // the current order before it decides between resuming and starting.
        await widget.player.syncLocalQueue(_local.queue);

        // A pause is not a new start: the same local song simply continues.
        if (widget.player.localCurrent != null) {
          await widget.player.resume();
        } else {
          await widget.player.playLocalQueue(_local.queue);
        }
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
            _ => 'Das Lied konnte nicht gespielt werden: $error',
          };
          _busy = false;
        });
      }
      return;
    }

    if (widget.player.queue.isEmpty) {
      setState(() {
        _note = 'Die Warteschlange ist leer, es gibt nichts zu spielen.';
        _busy = false;
      });
      return;
    }

    setState(() => _busy = true);
    try {
      await widget.player.playCurrent();
      if (!mounted) return;
      setState(() {
        _note = null;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      // A song that fails in the middle of a stream cannot become a JSON error: the status
      // was already sent, so the only sign is that the body stopped.
      setState(() {
        _note = 'Das Lied konnte nicht gespielt werden: $error';
        _busy = false;
      });
    }
  }

  Future<void> _next() async {
    setState(() => _busy = true);
    if (widget.localMode) {
      // The sheet shows the stored queue; the player may still hold an older copy.
      await widget.player.syncLocalQueue(_local.queue);
      if (!mounted) return;
      // Nothing from the stored list is open yet (a first tap or after a restart), so next
      // means start it — not that the list has ended.
      if (widget.player.localCurrent == null) return _play();
    }

    try {
      final moved = await widget.player.next();
      if (!mounted) return;
      setState(() {
        _note = moved ? null : 'Das war das letzte Lied der Warteschlange.';
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _note = 'Das nächste Lied konnte nicht gespielt werden: $error';
        _busy = false;
      });
    }
  }

  Future<void> _remove(int position) async {
    if (widget.localMode) {
      final index = position - 1;
      if (index < 0 || index >= _local.queue.length) return;

      setState(() => _busy = true);
      try {
        // The player holds its own copy of the order, so it drops the same song by identity.
        await widget.player.removeLocal(_local.queue[index]);
        _local.removeFromQueue(index);
        if (!mounted) return;
        setState(() => _note = 'Position $position entfernt.');
      } catch (error) {
        if (!mounted) return;
        setState(() => _note = 'Das Lied konnte nicht entfernt werden: $error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    setState(() => _busy = true);

    // The row being removed may be the one that is playing. The mirror moves to the song
    // that takes the slot, so the audio has to move with it; otherwise the sheet shows the
    // next song while the removed one is still audible, and the song after it is skipped
    // when the current one ends.
    final wasPlaying = widget.player.queue.current?.position == position;

    try {
      await widget.queues.remove(position);
      if (!mounted) return;

      if (!widget.player.queue.removeAt(position)) {
        // Another device can have changed the queue, so the mirror may be shorter than it.
        // That is not a removal this sheet had, so it must not be reported as one.
        setState(() {
          _note = 'Position $position war nicht mehr in der Liste, die dieses Fenster zeigt. Bitte aktualisieren.';
          _busy = false;
        });
        return;
      }

      setState(() {
        _note = 'Position $position entfernt.';
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
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }

  Future<void> _clear() async {
    if (widget.localMode) {
      setState(() => _busy = true);
      try {
        await widget.player.clearLocalQueue();
        _local.clearQueue();
        if (!mounted) return;
        setState(() => _note = 'Warteschlange geleert.');
      } catch (error) {
        if (!mounted) return;
        setState(() => _note = 'Die Warteschlange konnte nicht geleert werden: $error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    setState(() => _busy = true);
    try {
      await widget.queues.clear();
      // The sheet can be closed while the call is in flight. The app-wide mirror and the
      // audio still have to follow the server, so they are not behind the mounted guard.
      await widget.player.stop();
      widget.player.queue.clear();
      if (!mounted) return;
      setState(() {
        _note = 'Warteschlange geleert.';
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

  /// Puts a song from the server library at the end of the queue. The server answers the
  /// slot it got, so the sheet shows the same number the next read would return.
  Future<void> _add(Track track) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      final entry = await widget.queues.append(track.id);
      if (!mounted) return;

      // The mirror only matches the list the server appended to when it was read from the
      // same state. After a failed or stale read it is rebuilt from the server instead of
      // showing a slot number that cannot be right.
      if (entry.position == widget.player.queue.length + 1) {
        widget.player.queue.append(entry);
      } else {
        await _read();
        if (!mounted) return;
      }

      setState(() => _note = '${track.title} an Position ${entry.position} gelegt.');
    } on QueueException catch (error) {
      if (!mounted) return;
      setState(() => _note = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The same for a file on the device: the stored queue and the player's copy both get it,
  /// so "Nächstes Lied" plays it.
  Future<void> _addLocal(LocalTrack track) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      _local.addToQueue(track);
      // Only the list the player is playing from may be re-synced: a single song opened from
      // the library is not part of the stored order, and syncing would stop it.
      final current = widget.player.localCurrent;
      if (current == null || _local.queue.contains(current)) {
        await widget.player.syncLocalQueue(_local.queue);
      }
      if (!mounted) return;
      setState(() => _note = '${track.title} in die Warteschlange gelegt.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _note = 'Das Lied konnte nicht hinzugefügt werden: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentTitle = widget.localMode ? widget.player.localTitle : widget.player.queue.current?.title;

    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                Text('Warteschlange', style: theme.textTheme.titleLarge),
                const Spacer(),
                IconButton(
                  tooltip: 'Schließen',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Text(
              currentTitle == null ? 'Kein Lied wird gespielt.' : 'Gerade: $currentTitle',
              style: theme.textTheme.labelLarge,
            ),
          ),
          if (_note != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(_note!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
            ),
          const TabBar(
            tabs: [
              Tab(text: 'Warteschlange'),
              Tab(text: 'Lieder hinzufügen'),
            ],
          ),
          Expanded(
            child: TabBarView(children: [_queueTab(), _addTab()]),
          ),
        ],
      ),
    );
  }

  Widget _queueTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton(onPressed: _busy ? null : _play, child: const Text('Spielen')),
              TextButton(onPressed: _busy ? null : () => widget.player.pause(), child: const Text('Pause')),
              TextButton(onPressed: _busy ? null : _next, child: const Text('Nächstes Lied')),
              // A local queue lives on the device, so reading it again is pointless.
              if (!widget.localMode)
                TextButton(onPressed: _busy ? null : _read, child: const Text('Aktualisieren')),
              TextButton(onPressed: _busy ? null : _clear, child: const Text('Leeren')),
            ],
          ),
        ),
        Expanded(child: _rows()),
      ],
    );
  }

  Widget _rows() {
    if (widget.localMode) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        itemCount: _local.queue.length,
        itemBuilder: (context, index) {
          final track = _local.queue[index];

          return ListTile(
            leading: Text('${index + 1}'),
            title: Text(track.title),
            // The player holds the same track objects, so this is still the row it plays.
            selected: identical(widget.player.localCurrent, track),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _busy ? null : () => _remove(index + 1),
            ),
          );
        },
      );
    }

    final entries = widget.player.queue.entries;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final current = index == widget.player.queue.index;

        return ListTile(
          leading: Text('${entry.position}'),
          title: Text(entry.title),
          selected: current,
          trailing: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : () => _remove(entry.position),
          ),
        );
      },
    );
  }

  Widget _addTab() {
    final theme = Theme.of(context);

    if (_songsNote != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_songsNote!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
        ),
      );
    }
    if (_loadingSongs) return const Center(child: CircularProgressIndicator());

    if (widget.localMode) {
      if (_local.tracks.isEmpty) return const Center(child: Text('Keine Songs auf diesem Gerät.'));

      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        itemCount: _local.tracks.length,
        itemBuilder: (context, index) {
          final track = _local.tracks[index];
          return ListTile(
            leading: const Icon(Icons.audio_file),
            title: Text(track.title),
            subtitle: const Text('Auf diesem Gerät'),
            trailing: IconButton(
              tooltip: 'Hinzufügen',
              icon: const Icon(Icons.add),
              onPressed: _busy ? null : () => _addLocal(track),
            ),
          );
        },
      );
    }

    if (_songs.isEmpty) return const Center(child: Text('Die Bibliothek ist leer.'));

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      itemCount: _songs.length,
      itemBuilder: (context, index) {
        final track = _songs[index];
        return ListTile(
          leading: const Icon(Icons.audio_file),
          title: Text(track.title),
          subtitle: track.artist.isEmpty ? null : Text(track.artist),
          trailing: IconButton(
            tooltip: 'Hinzufügen',
            icon: const Icon(Icons.add),
            onPressed: _busy ? null : () => _add(track),
          ),
        );
      },
    );
  }
}
