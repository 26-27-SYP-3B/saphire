import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/library/data/library_repository.dart';
import '../../features/library/data/local_library.dart';
import '../../features/player/data/queue_repository.dart';
import '../../features/player/domain/player.dart';
import '../../features/player/presentation/queue_sheet.dart';

/// The bar every signed-in page shows at the bottom: what is current in the queue, and
/// the buttons that move it. It is the same widget on every page, so it listens to the
/// player instead of keeping its own copy of what is playing — a song that ends on its
/// own has no tap behind it, and a bar that only rebuilt on a tap would keep showing the
/// song that just finished.
class PlayerBar extends StatefulWidget {
  const PlayerBar({
    super.key,
    required this.player,
    required this.queues,
    required this.library,
    this.localMode = false,
    this.localLibrary,
  });

  final QueuePlayer player;

  /// The queue behind the list button: the sheet it opens reads and appends through this.
  final QueueRepository queues;

  /// What the sheet's add tab lists.
  final LibraryRepository library;

  /// Without a server the queue is the stored one and the songs come from the device.
  final bool localMode;

  /// The queue stored on the device. Without a server that queue is all there is, and the
  /// player only learns it once it is started, so the bar reads it here. Null in a test
  /// that does not care about local mode.
  final LocalLibrary? localLibrary;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  StreamSubscription<void>? _changes;
  String? _note;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _control(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      // Opening a song is not a JSON answer from the server, so the message here is ours.
      if (mounted) setState(() => _note = 'Das Lied konnte nicht gespielt werden: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What pressing play means when nothing is open yet.
  ///
  /// A local song that is open resumes as it is. A paused server song continues where it
  /// was. A queue that was filled but never started plays from its first song. Without a
  /// server, the queue stored on the device is what starts — otherwise the button would
  /// have nothing to open on a fresh start.
  Future<void> _play() {
    if (widget.player.localTitle != null) return widget.player.resume();
    if (widget.player.queue.current != null && widget.player.failure == null) return widget.player.resume();
    if (!widget.player.queue.isEmpty) return widget.player.playCurrent();

    final stored = widget.localLibrary?.queue ?? const [];
    if (stored.isNotEmpty) return widget.player.playLocalQueue(stored);
    return widget.player.playCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = widget.player.localCurrent;
    final current = widget.player.queue.current;
    final playing = widget.player.playing;
    // A local file has no slot in the server queue, so the bar follows what the player
    // opened last rather than the queue alone.
    final title = local?.title ?? current?.title;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outline))),
      child: Row(
        children: [
          Icon(playing ? Icons.play_arrow : Icons.audio_file,
              size: 22, color: playing ? scheme.primary : scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title ?? 'Nichts wird abgespielt',
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  // What is known about the queue: an error, or the slot that is current,
                  // or what would start something.
                  _note ??
                      widget.player.failure ??
                      (local != null
                          ? 'Lokal · dieses Gerät'
                          : current == null
                              ? 'Suche ein Lied und öffne es, oder fülle die Warteschlange.'
                              : 'Warteschlange · Slot ${current.position}'),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Warteschlange',
            onPressed: () => showQueueSheet(
              context,
              queues: widget.queues,
              library: widget.library,
              player: widget.player,
              localMode: widget.localMode,
              localLibrary: widget.localLibrary,
            ),
            icon: const Icon(Icons.queue_music),
          ),
          IconButton(
            tooltip: playing ? 'Pause' : 'Abspielen',
            // A local song resumes where it was; _play knows that and what to start when
            // nothing is open yet.
            onPressed: _busy
                ? null
                : () => _control(() => playing
                    ? widget.player.pause()
                    : widget.player.localCurrent != null
                        ? widget.player.resume()
                        : _play()),
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          ),
          IconButton(
            tooltip: 'Nächstes Lied',
            onPressed: _busy ? null : () => _control(() => widget.player.next()),
            icon: const Icon(Icons.skip_next),
          ),
        ],
      ),
    );
  }
}
