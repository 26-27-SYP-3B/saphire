import 'dart:async';

import 'package:flutter/material.dart';

import '../../features/player/domain/player.dart';

/// The bar every signed-in page shows at the bottom: what is current in the queue, and
/// the buttons that move it. It is the same widget on every page, so it listens to the
/// player instead of keeping its own copy of what is playing — a song that ends on its
/// own has no tap behind it, and a bar that only rebuilt on a tap would keep showing the
/// song that just finished.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, required this.player});

  final QueuePlayer player;

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
            tooltip: playing ? 'Pause' : 'Abspielen',
            // A local song resumes where it was; playCurrent would clear the local list
            // and leave nothing to play.
            onPressed: _busy
                ? null
                : () => _control(() => playing
                    ? widget.player.pause()
                    : local != null
                        ? widget.player.resume()
                        : widget.player.playCurrent()),
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
