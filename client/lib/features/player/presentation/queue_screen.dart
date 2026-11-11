import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../library/data/local_library.dart';
import '../data/queue_repository.dart';
import '../domain/player.dart';
import '../domain/queue.dart';

/// The queue: what is lined up, which song is current, and what happens when a song
/// ends.
///
/// Nothing here knows where the songs came from. The list was filled from a source —
/// a playlist, one song, the library — and after that a queue is just an order. So this
/// page is also the page a plain queue feature would use later: it needs a second way to
/// fill the list, not a different list.
class QueueScreen extends StatefulWidget {
  const QueueScreen({
    super.key,
    required this.queues,
    required this.queue,
    required this.player,
    required this.session,
    this.settings,
    this.localLibrary,
  });

  final QueueRepository queues;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;

  /// Null in a test that does not care about local mode: the stores then stay in memory.
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  String? _note;
  bool _busy = false;
  StreamSubscription<void>? _changes;

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  @override
  void initState() {
    super.initState();
    // The player moves on its own when a song ends. Without a listener the page would
    // only rebuild when the user did something, and it would keep showing the song that
    // just finished.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // The queue lives on the server, so another device may have changed it since the
    // last look. Reading it again is what makes the page show the current list.
    _read();
  }

  @override
  void dispose() {
    // The player belongs to the whole app, so only this page's listener is dropped here.
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    // The local queue is on the device. There is nothing to fetch and no token to send.
    if (_settings.localMode) {
      setState(() {
        _note = _local.queue.isEmpty
            ? 'Die Warteschlange ist leer. Lege auf der Startseite ein Lied hinein oder starte eine Playlist.'
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
      // page keeps pointing at it; if it is gone, the audio stops with it, so the page and
      // the audio say the same thing.
      final current = widget.player.playing ? widget.queue.current : null;
      var keep = -1;
      for (var i = 0; i < entries.length; i++) {
        if (current != null && entries[i].trackId == current.trackId) {
          keep = i;
          break;
        }
      }

      setState(() {
        widget.queue.fill(entries);
        widget.queue.index = keep;
        _note = entries.isEmpty ? 'Die Warteschlange ist leer. Starte eine Playlist oder füge ein Lied hinzu.' : null;
        _busy = false;
      });

      if (current != null && keep < 0) await widget.player.stop();
    } on QueueException catch (error) {
      if (!mounted) return;
      // Only a 401 says this token is gone; a 429 or a 400 is not a lost login. When the
      // app does drop it, the guard and the page agree on the same session.
      if (error.statusCode == 401) widget.session.clear();
      setState(() {
        _note = error.message;
        _busy = false;
      });
    }
  }
  Future<void> _play() async {
    if (_settings.localMode) {
      if (_local.queue.isEmpty) {
        setState(() => _note = 'Die Warteschlange ist leer, es gibt nichts zu spielen.');
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

    if (widget.queue.isEmpty) {
      setState(() => _note = 'Die Warteschlange ist leer, es gibt nichts zu spielen.');
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
      // A song that fails in the middle of a stream cannot become a JSON error: the
      // status was already sent, so the only sign is that the body stopped.
      setState(() {
        _note = 'Das Lied konnte nicht gespielt werden: $error';
        _busy = false;
      });
    }
  }

  Future<void> _next() async {
    setState(() => _busy = true);
    if (_settings.localMode) {
      // This page shows the stored queue; the player may still hold an older copy.
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
    if (_settings.localMode) {
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
    // that takes the slot, so the audio has to move with it; otherwise the page shows the
    // next song while the removed one is still audible, and the song after it is skipped
    // when the current one ends.
    final wasPlaying = widget.queue.current?.position == position;

    try {
      await widget.queues.remove(position);
      if (!mounted) return;

      if (!widget.queue.removeAt(position)) {
        // Another device can have changed the queue, so the mirror may be shorter than it.
        // That is not a removal this page had, so it must not be reported as one.
        setState(() {
          _note = 'Position $position war nicht mehr in der Liste, die diese Seite zeigt. Bitte aktualisieren.';
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
    if (_settings.localMode) {
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
      if (!mounted) return;
      await widget.player.stop();
      widget.queue.clear();
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

  // What the page says happened: an action of this page, or what the player reported on
  // its own when a song ended and the next one could not be opened.
  String? _message() => _note ?? widget.player.failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final message = _message();
    final currentTitle = _settings.localMode ? widget.player.localTitle : widget.queue.current?.title;

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Warteschlange', style: theme.textTheme.displaySmall),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton(onPressed: _busy ? null : _play, child: const Text('Spielen')),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _busy ? null : () => widget.player.pause(), child: const Text('Pause')),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _busy ? null : _next, child: const Text('Nächstes Lied')),
                    // A local queue lives on the device, so reading it again is pointless.
                    if (!_settings.localMode) ...[
                      const SizedBox(width: 8),
                      TextButton(onPressed: _busy ? null : _read, child: const Text('Aktualisieren')),
                    ],
                    const SizedBox(width: 8),
                    TextButton(onPressed: _busy ? null : _clear, child: const Text('Leeren')),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  currentTitle == null ? 'Kein Lied wird gespielt.' : 'Gerade: $currentTitle',
                  style: theme.textTheme.labelLarge,
                ),
                if (message != null) ...[
                  const SizedBox(height: 10),
                  Text(message, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error)),
                ],
              ],
            ),
          ),
          Expanded(child: _rows()),
        ],
      ),
    );
  }

  Widget _rows() {
    if (_settings.localMode) {
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

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      itemCount: widget.queue.length,
      itemBuilder: (context, index) {
        final entry = widget.queue.entries[index];
        final current = index == widget.queue.index;

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
}
