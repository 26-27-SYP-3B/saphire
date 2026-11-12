import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/player.dart';

/// The player as a phone shows it: one song filling the screen, with the controls a thumb can
/// reach. It plays nothing itself — it moves the same player the bar at the bottom moves, so a
/// song keeps running when this view is closed and the bar and this view cannot name different
/// songs.
///
/// Swiping down leaves it, because that is the gesture a phone uses to go back; nothing is
/// stopped here, so playback is not interrupted by closing the view.
class PlayerView extends StatefulWidget {
  const PlayerView({
    super.key,
    required this.player,
    this.onQueueOpen,
    this.onClose,
  });

  final QueuePlayer player;

  /// The queue is the other view of the same frame, so this view asks the frame for it through the
  /// same callback the bar uses.
  final VoidCallback? onQueueOpen;

  /// Back to the view this one was opened from.
  final VoidCallback? onClose;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  StreamSubscription<void>? _changes;
  StreamSubscription<Duration>? _position;
  String? _note;
  bool _busy = false;

  /// Where the song is, kept from the player's stream: a progress bar that only updated on a tap
  /// would stand still while the song runs.
  Duration _at = Duration.zero;

  // What this view set as the volume. The player is the thing that turns it down, but a slider
  // needs the value it last had.
  double _volume = 1.0;

  @override
  void initState() {
    super.initState();
    // A song that ends on its own has no tap behind it, so without a listener this view would keep
    // showing the song that just finished.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    _position = widget.player.positionStream.listen((position) {
      if (mounted) setState(() => _at = position);
    });
  }

  @override
  void dispose() {
    _changes?.cancel();
    _position?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _note = 'Das Lied konnte nicht gespielt werden: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = widget.player.localCurrent;
    final entry = widget.player.queue.current;
    final title = local?.title ?? entry?.title;
    final total = widget.player.duration;
    final playing = widget.player.playing;

    return Dismissible(
      key: const ValueKey('player'),
      direction: DismissDirection.down,
      onDismissed: (_) => widget.onClose?.call(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title ?? 'Nichts wird abgespielt', style: theme.textTheme.titleMedium),
                    Text(
                      // shortcut: the acceptance criteria ask for an Interpret, but neither a queue
                      // answer nor a picked file names one, so this line says where the song is.
                      // Upgrade: `artist` in the queue response (api-docs.md), then this line shows
                      // it.
                      _note ??
                          widget.player.failure ??
                          (local != null
                              ? 'Lokal · dieses Gerät'
                              : entry == null
                                  ? 'Warteschlange ist leer'
                                  : 'Warteschlange · Slot ${entry.position}'),
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Warteschlange',
                onPressed: widget.onQueueOpen,
                icon: const Icon(Icons.queue_music),
              ),
              IconButton(tooltip: 'Player schließen', icon: const Icon(Icons.expand_more), onPressed: widget.onClose),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('0:00'),
              Expanded(
                child: Slider(
                  // A song whose length the player does not know cannot be seeked to a tenth of it,
                  // so the bar stays where it is.
                  max: total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1,
                  value: total.inMilliseconds > 0
                      ? (_at.inMilliseconds.clamp(0, total.inMilliseconds)).toDouble()
                      : 0,
                  onChanged: total.inMilliseconds > 0
                      ? (value) => _run(() => widget.player.seek(Duration(milliseconds: value.round())))
                      : null,
                ),
              ),
              Text(_clock(total)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                tooltip: 'Vorheriges Lied',
                onPressed: title == null || _busy ? null : () => _run(() => widget.player.previous()),
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                // The ten-second jumps are what a phone has buttons for; a song is not restarted by
                // them, only moved inside itself.
                tooltip: '10 Sekunden zurück',
                onPressed: total == Duration.zero || _busy ? null : () => _run(() => widget.player.skip(const Duration(seconds: -10))),
                icon: const Icon(Icons.replay_10),
              ),
              IconButton(
                tooltip: playing ? 'Pause' : 'Wiedergeben',
                onPressed: title == null || _busy ? null : () => _run(playing ? widget.player.pause : widget.player.resume),
                icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              ),
              IconButton(
                tooltip: '10 Sekunden vor',
                onPressed: total == Duration.zero || _busy ? null : () => _run(() => widget.player.skip(const Duration(seconds: 10))),
                icon: const Icon(Icons.forward_10),
              ),
              IconButton(
                tooltip: 'Nächstes Lied',
                onPressed: title == null || _busy ? null : () => _run(() => widget.player.next()),
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 20),
              const Icon(Icons.volume_down),
              Expanded(
                child: Slider(
                  max: 1,
                  value: _volume,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() => _volume = value);
                          _run(() => widget.player.setVolume(value));
                        },
                ),
              ),
              const SizedBox(width: 20),
            ],
          ),
        ],
      ),
    );
  }

  static String _clock(Duration at) =>
      '${at.inMinutes}:${(at.inSeconds % 60).toString().padLeft(2, '0')}';
}
