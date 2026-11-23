import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/player.dart';
import '../domain/queue.dart';

/// The colours the player adds to the app's palette: a card a little lighter than the canvas,
/// the blue an active title uses, and the muted bars of the seek line.
const playerCard = Color(0xFF171C26);
const playerCardBorder = Color(0xFF242B3A);
const playerAccent = Color(0xFF6D8DFF);
const playerBarMuted = Color(0xFF39445C);

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
  /// same callback the bar uses. The compact queue inside the player uses it for its "edit" button;
  /// the frame then shows the full panel with search, history and the row menu.
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

  /// Whether the compact queue sits over the cover. It is a sheet inside the player, not the
  /// frame's full queue, so the controls stay where they are and playback is not interrupted.
  bool _queueOpen = false;

  /// Where the song is, kept from the player's stream: a progress bar that only updated on a tap
  /// would stand still while the song runs.
  Duration _at = Duration.zero;

  // Where the thumb is while a finger is on the progress bar. The position stream keeps running,
  // so without this the thumb would be pulled back under the finger.
  double? _drag;

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

  // The volume belongs to the player, not this page: the page is recreated while the audio keeps
  // playing, and a slider that started at its default would show a volume that is not set.
  void _setVolume(double value) {
    setState(() {});
    _run(() => widget.player.setVolume(value));
  }

  void _toggleMute() => _setVolume(widget.player.volume > 0 ? 0 : widget.player.volumeBeforeMute);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = widget.player.localCurrent;
    final entry = widget.player.queue.current;
    final title = local?.title ?? entry?.title;
    final subtitle = _note ?? widget.player.statusNote;
    final failed = _note != null || widget.player.failure != null;
    final total = widget.player.duration;
    final playing = widget.player.playing;

    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone has no room for a small card in the middle: the player fills the screen the
        // way the app does. A wider window gets the centred card the mock shows.
        final phone = constraints.maxWidth < 600;
        final width = phone ? constraints.maxWidth - 24 : math.min(constraints.maxWidth - 48, 480.0);
        final height = phone ? constraints.maxHeight - 24 : math.min(constraints.maxHeight - 48, width * 1.6);
        final sheetHeight = math.min(
          math.max(84.0, 64.0 + widget.player.queue.length * 56.0),
          height * 0.56,
        );

        return Center(
          child: Dismissible(
            key: const ValueKey('player'),
            direction: DismissDirection.down,
            onDismissed: (_) => widget.onClose?.call(),
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: playerCard,
                border: Border.all(color: playerCardBorder),
                borderRadius: BorderRadius.circular(36),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 30,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Stack(
                children: [
                  Column(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Expanded(child: _cover(context, title)),
                            const SizedBox(height: 16),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                title ?? 'Nichts wird abgespielt',
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.9,
                                  color: scheme.onSurface,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                subtitle,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: failed ? scheme.error : scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(height: 14),
                            _progress(context, total),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _controls(context, title, total, playing),
                      const SizedBox(height: 6),
                      _moreControls(context, title, total),
                    ],
                  ),
                  if (_queueOpen)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 134,
                      child: SizedBox(height: sheetHeight, child: _queueSheet(context)),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The cover area. The library keeps no picture per song, so the placeholder is a soft navy to
  /// warm gradient with the app's note mark; it is the same size a real cover would use.
  Widget _cover(BuildContext context, String? title) {
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF0B1220), Color(0xFF161A24), Color(0xFF38251C)],
                stops: [0, 0.55, 1],
              ),
            ),
            child: Center(
              child: Icon(
                Icons.music_note,
                size: 72,
                color: Colors.white.withValues(alpha: 0.06),
              ),
            ),
          ),
        ),
        if (widget.onClose != null)
          Positioned(
            left: 8,
            top: 8,
            child: IconButton(
              tooltip: 'Player schließen',
              onPressed: widget.onClose,
              icon: const Icon(Icons.keyboard_arrow_down),
              color: Colors.white.withValues(alpha: 0.72),
            ),
          ),
        if (title == null)
          const Positioned(
            left: 0,
            right: 0,
            bottom: 14,
            child: Text(
              'Kein Lied geöffnet',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ),
      ],
    );
  }

  Widget _progress(BuildContext context, Duration total) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final totalMs = total.inMilliseconds;
    final positionMs = (_drag ?? _at.inMilliseconds.toDouble()).clamp(0.0, totalMs > 0 ? totalMs.toDouble() : 1.0);
    final progress = totalMs > 0 ? positionMs / totalMs : 0.0;

    return Row(
      children: [
        // While a finger is on the bar the label follows the thumb, so the target time is
        // readable before the release that seeks.
        Text(
          _clock(_drag == null ? _at : Duration(milliseconds: _drag!.round())),
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _WaveformPainter(progress: progress)),
                ),
                Positioned.fill(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      activeTrackColor: Colors.transparent,
                      inactiveTrackColor: Colors.transparent,
                      disabledActiveTrackColor: Colors.transparent,
                      disabledInactiveTrackColor: Colors.transparent,
                      thumbColor: Colors.white,
                      disabledThumbColor: playerBarMuted,
                      overlayColor: Colors.white.withValues(alpha: 0.12),
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 8),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
                    ),
                    child: Slider(
                      // A song whose length the player does not know cannot be seeked to a tenth of
                      // it, so the bar stays where it is.
                      max: totalMs > 0 ? totalMs.toDouble() : 1,
                      value: totalMs > 0 ? positionMs : 0,
                      onChanged: totalMs > 0 ? (value) => setState(() => _drag = value) : null,
                      // Only the release seeks: one seek per drag frame fights the position stream
                      // and most of the jumps would be thrown away.
                      onChangeEnd: totalMs > 0
                          ? (value) {
                              final to = Duration(milliseconds: value.round());
                              setState(() {
                                _drag = null;
                                _at = to;
                              });
                              _run(() => widget.player.seek(to));
                            }
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _clock(total),
          style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, String? title, Duration total, bool playing) {
    final disabled = title == null || _busy;

    return Row(
      children: [
        _squareButton(
          tooltip: 'Warteschlange',
          icon: Icons.queue_music,
          active: _queueOpen,
          onPressed: () => setState(() => _queueOpen = !_queueOpen),
        ),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                tooltip: 'Vorheriges Lied',
                iconSize: 30,
                onPressed: disabled ? null : () => _run(() => widget.player.previous()),
                icon: const Icon(Icons.skip_previous),
              ),
              const SizedBox(width: 10),
              _playButton(playing, disabled),
              const SizedBox(width: 10),
              IconButton(
                tooltip: 'Nächstes Lied',
                iconSize: 30,
                onPressed: disabled ? null : () => _run(() => widget.player.next()),
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
        ),
        // Balances the queue button so the transport stays centred on the card.
        const SizedBox(width: 44, height: 44),
      ],
    );
  }

  Widget _playButton(bool playing, bool disabled) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: IconButton(
        tooltip: playing ? 'Pause' : 'Wiedergeben',
        onPressed: disabled ? null : () => _run(playing ? widget.player.pause : widget.player.resume),
        icon: Icon(playing ? Icons.pause : Icons.play_arrow),
        iconSize: 34,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF0E1420),
          disabledBackgroundColor: Colors.white24,
          minimumSize: const Size(64, 64),
          shape: const CircleBorder(),
        ),
      ),
    );
  }

  Widget _squareButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    bool active = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? playerAccent.withValues(alpha: 0.16) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              border: Border.all(color: active ? playerAccent : playerCardBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: active ? playerAccent : scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  Widget _moreControls(BuildContext context, String? title, Duration total) {
    final scheme = Theme.of(context).colorScheme;
    final disabled = title == null || _busy;
    final jumpDisabled = disabled || total == Duration.zero;

    return Row(
      children: [
        IconButton(
          tooltip: 'Zufällige Wiedergabe',
          iconSize: 20,
          onPressed: disabled ? null : () => setState(() => widget.player.shuffle = !widget.player.shuffle),
          icon: Icon(Icons.shuffle, color: widget.player.shuffle ? playerAccent : scheme.onSurfaceVariant),
        ),
        IconButton(
          tooltip: '10 Sekunden zurück',
          iconSize: 20,
          onPressed: jumpDisabled ? null : () => _run(() => widget.player.skip(const Duration(seconds: -10))),
          icon: const Icon(Icons.replay_10),
        ),
        IconButton(
          tooltip: '10 Sekunden vor',
          iconSize: 20,
          onPressed: jumpDisabled ? null : () => _run(() => widget.player.skip(const Duration(seconds: 10))),
          icon: const Icon(Icons.forward_10),
        ),
        IconButton(
          tooltip: 'Wiederholen',
          iconSize: 20,
          onPressed: disabled ? null : () => setState(() => widget.player.repeatOne = !widget.player.repeatOne),
          icon: Icon(Icons.repeat_one, color: widget.player.repeatOne ? playerAccent : scheme.onSurfaceVariant),
        ),
        IconButton(
          tooltip: widget.player.volume == 0 ? 'Ton an' : 'Stumm',
          iconSize: 20,
          onPressed: _busy ? null : _toggleMute,
          icon: Icon(widget.player.volume == 0 ? Icons.volume_off : Icons.volume_up),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: playerAccent,
              inactiveTrackColor: playerBarMuted,
              thumbColor: scheme.onSurface,
              overlayColor: playerAccent.withValues(alpha: 0.12),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              max: 1,
              value: widget.player.volume,
              onChanged: _busy ? null : _setVolume,
            ),
          ),
        ),
      ],
    );
  }

  /// The compact queue the player opens. It is the same list the frame's full panel shows, but
  /// only what a listener needs while the song runs: the order, the artist and the length. A row
  /// starts its song; the tune button asks the frame for the full panel with the row menu.
  Widget _queueSheet(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = widget.player.queue.entries;
    final current = widget.player.queue.current;

    return Material(
      color: const Color(0xFF202633),
      elevation: 10,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Warteschlange',
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${entries.length} Titel',
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
                if (widget.onQueueOpen != null)
                  IconButton(
                    tooltip: 'Warteschlange bearbeiten',
                    iconSize: 18,
                    onPressed: () {
                      setState(() => _queueOpen = false);
                      widget.onQueueOpen?.call();
                    },
                    icon: const Icon(Icons.tune),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: playerCardBorder),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      'Die Warteschlange ist leer.',
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      final active = identical(entry, current);
                      return _queueRow(context, index, entry, active);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _queueRow(BuildContext context, int index, QueueEntry entry, bool active) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return InkWell(
      onTap: _busy ? null : () => _run(() => widget.player.playAt(entry)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.right,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: active ? playerAccent : scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: active ? playerAccent : scheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (entry.artist.isNotEmpty)
                    Text(
                      entry.artist,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              entry.durationMs > 0 ? _clock(Duration(milliseconds: entry.durationMs)) : '–',
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  static String _clock(Duration at) =>
      '${at.inMinutes}:${(at.inSeconds % 60).toString().padLeft(2, '0')}';
}

/// The seek line's bars. A fixed pattern keeps the line stable between rebuilds; only the colour
/// follows the position, so the bar reads like the waveform a music app uses.
class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 52;
    const barWidth = 3.0;
    final gap = (size.width - count * barWidth) / (count - 1);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    for (var index = 0; index < count; index++) {
      final at = index / (count - 1);
      final wave = (math.sin(index * 1.31) * 0.5 + 0.5) * (math.sin(index * 0.43 + 0.8) * 0.35 + 0.65);
      final height = (5 + (size.height - 10) * wave).clamp(5.0, size.height);
      paint.color = at <= progress ? playerAccent : playerBarMuted;
      final x = index * (barWidth + gap) + barWidth / 2;
      canvas.drawLine(
        Offset(x, size.height / 2 + height / 2),
        Offset(x, size.height / 2 - height / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) => oldDelegate.progress != progress;
}
