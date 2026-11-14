import 'package:flutter/material.dart';

import '../domain/player.dart';

/// The now-playing bar.
///
/// Play, pause and seeking are real: the server sends the file piece by piece and answers
/// a single byte range with 206, which is what a seek needs. Shuffle, repeat, previous
/// and next are not here, because a queue has no endpoints yet (api-docs.md, Upcoming) —
/// a control with nothing behind it only looks like a button.
class PlayerBar extends StatelessWidget {
  const PlayerBar({required this.player, super.key});

  final Player player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: scheme.outline))),
      child: StreamBuilder<Playback>(
        stream: player.playback,
        initialData: player.current,
        builder: (context, snapshot) {
          final state = snapshot.data ?? player.current;
          final song = state.song;
          final length = state.duration;
          // The text shows the same position the slider can show, so the two cannot
          // disagree when the engine reports a position past the length it gave.
          final shown = length == null || state.position <= length ? state.position : length;

          return Row(
            children: [
              Icon(
                song == null ? Icons.audio_file : Icons.graphic_eq,
                size: 22,
                color: song == null ? scheme.onSurfaceVariant : scheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(song?.title ?? 'Nichts wird abgespielt', style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    if (song == null)
                      Text(
                        'Öffne ein Lied in der Bibliothek.',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      )
                    else if (state.error != null)
                      // The server's own words, so the message names the song that cannot
                      // be played instead of a general playback failure.
                      Text(state.error!, style: TextStyle(color: scheme.error))
                    else ...[
                      Text(
                        '${_time(shown)} · ${length == null ? 'Länge unbekannt' : _time(length)}',
                        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(height: 2),
                      _seek(context, state),
                    ],
                  ],
                ),
              ),
              if (song != null)
                IconButton(
                  tooltip: state.playing ? 'Pause' : 'Wiedergeben',
                  onPressed: () => player.toggle(),
                  icon: Icon(state.playing ? Icons.pause : Icons.play_arrow),
                ),
            ],
          );
        },
      ),
    );
  }

  /// A slider when the length is known, because that is a control the player can use.
  /// While the stream has not reported a length there is nothing to seek in, so the bar
  /// only shows that it is still reading.
  Widget _seek(BuildContext context, Playback state) {
    final total = state.duration;
    if (total == null || total <= Duration.zero) {
      return LinearProgressIndicator(minHeight: 3);
    }

    final max = total.inMicroseconds.toDouble();
    return Slider(
      value: state.position.inMicroseconds.toDouble().clamp(0, max),
      max: max,
      onChanged: (value) => player.seekTo(Duration(microseconds: value.round())),
    );
  }

  String _time(Duration time) {
    final seconds = time.inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
