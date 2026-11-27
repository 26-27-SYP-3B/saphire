import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../features/library/data/local_library.dart';
import '../../features/player/domain/player.dart';
import 'track_art.dart';

/// The player at the bottom of every page, in the two shapes the app has:
///
/// * a phone gets the mini player Spotify has: cover, title, artist, play/pause and a thin
///   progress line, tapped to open the full player;
/// * a wide window gets the desktop bar: song on the left, transport and progress in the middle,
///   volume and the queue on the right.
///
/// It listens to the player instead of keeping its own copy of what is current. A song that ends
/// on its own has no tap behind it, and a bar that only rebuilt on a tap would name the song that
/// just finished.
class PlayerBar extends StatefulWidget {
  const PlayerBar({
    super.key,
    required this.player,
    this.localMode = false,
    this.localLibrary,
    this.onQueueOpen,
    this.onPlayerOpen,
  });

  final QueuePlayer player;

  /// What the list button does. The queue belongs to the frame the page is drawn in, so the bar
  /// does not open it by itself: the frame decides whether that is the column on the right or the
  /// whole page.
  final VoidCallback? onQueueOpen;

  /// What tapping the bar does. The full player is the same player seen close up, so the bar
  /// shows it and the frame decides where it is drawn.
  final VoidCallback? onPlayerOpen;

  /// Without a server the queue is the stored one and the songs come from the device.
  final bool localMode;

  /// The queue stored on the device. Without a server that queue is all there is, and the
  /// player only learns it once it is started, so the bar reads it here.
  final LocalLibrary? localLibrary;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  StreamSubscription<void>? _changes;
  StreamSubscription<Duration>? _position;
  String? _note;
  bool _busy = false;
  double? _drag;

  /// Where the song is, kept from the player's stream: the line only moves if it is redrawn.
  Duration _at = Duration.zero;

  @override
  void initState() {
    super.initState();
    _at = widget.player.position;
    _changes = widget.player.changes.listen((_) {
      if (!mounted) return;
      setState(() {
        _at = widget.player.position;
        _drag = null;
        _note = null;
      });
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

  Future<void> _control(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      // A message belongs to the action that failed; a later success must not keep it.
      if (mounted && _note != null) setState(() => _note = null);
    } catch (error) {
      if (mounted) {
        setState(() => _note = 'Das Lied konnte nicht gespielt werden: $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// What pressing play means when nothing is open yet.
  ///
  /// A local song that is open resumes as it is. A paused server song continues where it was.
  /// A queue that was filled but never started plays from its first song. Without a server, the
  /// queue stored on the device is what starts.
  Future<void> _play() {
    if (widget.player.localTitle != null) return widget.player.resume();
    if (widget.player.queue.current != null && widget.player.failure == null) {
      return widget.player.resume();
    }
    if (!widget.player.queue.isEmpty) return widget.player.playCurrent();

    final stored = widget.localLibrary?.queue ?? const [];
    if (stored.isNotEmpty) return widget.player.playLocalQueue(stored);
    return widget.player.playCurrent();
  }

  void _togglePlay() => _busy
      ? null
      : _control(
          () => widget.player.playing
              ? widget.player.pause()
              : widget.player.localCurrent != null
              ? widget.player.resume()
              : _play(),
        );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final local = widget.player.localCurrent;
    final entry = widget.player.queue.current;
    final playing = widget.player.playing;
    final title = local?.title ?? entry?.title;
    final cover = local?.cover ?? entry?.cover;
    final total = widget.player.duration;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 800;

        if (!wide) {
          final progress = total.inMilliseconds > 0
              ? (_drag ?? _at.inMilliseconds.toDouble()).clamp(
                      0.0,
                      total.inMilliseconds.toDouble(),
                    ) /
                    total.inMilliseconds
              : 0.0;

          return Material(
            color: fieldBackground,
            child: InkWell(
              onTap: widget.onPlayerOpen,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Row(
                      children: [
                        TrackArt(cover: cover, size: 44, radius: 4),
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
                                _note ?? widget.player.statusNote,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _note != null
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Warteschlange',
                          onPressed: widget.onQueueOpen,
                          icon: const Icon(Icons.queue_music),
                        ),
                        IconButton(
                          tooltip: playing ? 'Pause' : 'Abspielen',
                          onPressed: _togglePlay,
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        ),
                      ],
                    ),
                  ),
                  // The thin line Spotify puts at the bottom of the mini player. It is the
                  // progress of the song, not a control: seeking is the full player's job.
                  LinearProgressIndicator(
                    value: title == null ? 0 : progress,
                    minHeight: 2,
                    backgroundColor: hairline,
                    color: accentBright,
                  ),
                ],
              ),
            ),
          );
        }

        final desktop = constraints.maxWidth >= 1200;

        return Material(
          color: fieldBackground,
          child: InkWell(
            onTap: widget.onPlayerOpen,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: hairline)),
              ),
              child: Row(
                children: [
                  // The song on the left, in the order Spotify's desktop bar has it.
                  SizedBox(
                    width: desktop ? 300 : 220,
                    child: Row(
                      children: [
                        TrackArt(
                          cover: cover,
                          size: desktop ? 56 : 48,
                          radius: 4,
                        ),
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
                                _note ?? widget.player.statusNote,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _note != null
                                      ? scheme.error
                                      : scheme.onSurfaceVariant,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Gefällt mir',
                          onPressed: title == null
                              ? null
                              : () => setState(widget.player.toggleLike),
                          icon: Icon(
                            widget.player.isLiked
                                ? Icons.favorite
                                : Icons.favorite_border,
                            size: 20,
                            color: widget.player.isLiked
                                ? accentBright
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // The transport and the progress, centred.
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              tooltip: 'Zufällige Wiedergabe',
                              visualDensity: VisualDensity.compact,
                              onPressed: title == null
                                  ? null
                                  : () => setState(
                                      () => widget.player.shuffle =
                                          !widget.player.shuffle,
                                    ),
                              icon: Icon(
                                Icons.shuffle,
                                size: 20,
                                color: widget.player.shuffle
                                    ? accentBright
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Vorheriges Lied',
                              visualDensity: VisualDensity.compact,
                              onPressed: title == null || _busy
                                  ? null
                                  : () => _control(
                                      () => widget.player.previous(),
                                    ),
                              icon: const Icon(Icons.skip_previous, size: 22),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: playing ? 'Pause' : 'Abspielen',
                              onPressed: _togglePlay,
                              icon: Icon(
                                playing ? Icons.pause : Icons.play_arrow,
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: bodyText,
                                foregroundColor: canvas,
                                disabledBackgroundColor: hairline,
                                minimumSize: const Size(42, 42),
                              ),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Nächstes Lied',
                              visualDensity: VisualDensity.compact,
                              onPressed: title == null || _busy
                                  ? null
                                  : () => _control(() => widget.player.next()),
                              icon: const Icon(Icons.skip_next, size: 22),
                            ),
                            IconButton(
                              tooltip: 'Wiederholen',
                              visualDensity: VisualDensity.compact,
                              onPressed: title == null
                                  ? null
                                  : () => setState(
                                      () => widget.player.repeatOne =
                                          !widget.player.repeatOne,
                                    ),
                              icon: Icon(
                                Icons.repeat_one,
                                size: 20,
                                color: widget.player.repeatOne
                                    ? accentBright
                                    : scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Text(
                              _clock(
                                _drag == null
                                    ? _at
                                    : Duration(milliseconds: _drag!.round()),
                              ),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: _seekBar(theme, total)),
                            const SizedBox(width: 8),
                            Text(
                              _clock(total),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Volume, queue and the way to the full player on the right.
                  SizedBox(
                    width: desktop ? 300 : 96,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (desktop) ...[
                          IconButton(
                            tooltip: widget.player.volume == 0
                                ? 'Ton an'
                                : 'Stumm',
                            onPressed: () => widget.player.setVolume(
                              widget.player.volume == 0
                                  ? widget.player.volumeBeforeMute
                                  : 0,
                            ),
                            icon: Icon(
                              widget.player.volume == 0
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                              size: 20,
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                activeTrackColor: accentBright,
                                inactiveTrackColor: playerBarMuted,
                                thumbColor: bodyText,
                                thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 4,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 10,
                                ),
                              ),
                              child: Slider(
                                max: 1,
                                value: widget.player.volume,
                                onChanged: widget.player.setVolume,
                              ),
                            ),
                          ),
                        ],
                        IconButton(
                          tooltip: 'Warteschlange',
                          onPressed: widget.onQueueOpen,
                          icon: const Icon(Icons.queue_music, size: 20),
                        ),
                        IconButton(
                          tooltip: 'Vollbild-Player',
                          onPressed: widget.onPlayerOpen,
                          icon: const Icon(Icons.open_in_full, size: 18),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _seekBar(ThemeData theme, Duration total) {
    final totalMs = total.inMilliseconds;
    final value = totalMs > 0
        ? (_drag ?? _at.inMilliseconds.toDouble()).clamp(
            0.0,
            totalMs.toDouble(),
          )
        : 0.0;

    return SizedBox(
      height: 20,
      child: SliderTheme(
        data: SliderTheme.of(context).copyWith(
          trackHeight: 3,
          activeTrackColor: bodyText,
          inactiveTrackColor: playerBarMuted,
          thumbColor: bodyText,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
        ),
        child: Slider(
          max: totalMs > 0 ? totalMs.toDouble() : 1,
          value: value,
          onChanged:
              totalMs > 0 &&
                  (widget.player.queue.current != null ||
                      widget.player.localCurrent != null)
              ? (at) => setState(() => _drag = at)
              : null,
          onChangeEnd: totalMs <= 0
              ? null
              : (at) {
                  setState(() {
                    _drag = null;
                    _at = Duration(milliseconds: at.round());
                  });
                  _control(
                    () =>
                        widget.player.seek(Duration(milliseconds: at.round())),
                  );
                },
        ),
      ),
    );
  }

  static String _clock(Duration at) =>
      '${at.inMinutes}:${(at.inSeconds % 60).toString().padLeft(2, '0')}';
}
