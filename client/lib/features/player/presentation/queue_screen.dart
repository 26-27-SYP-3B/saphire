import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/session_store.dart';
import '../../playlists/data/playlist_repository.dart';
import '../data/queue_repository.dart';
import '../domain/player.dart';
import '../domain/queue.dart';
import 'queue_panel.dart';

/// The queue as its own view, which is what a phone has. Closing it goes back to the page the
/// person came from, and the song keeps playing: this page only shows the list, it never
/// touches the audio.
class QueueScreen extends StatelessWidget {
  const QueueScreen({
    super.key,
    required this.queues,
    required this.playlists,
    required this.queue,
    required this.player,
    required this.session,
  });

  final QueueRepository queues;
  final PlaylistRepository playlists;
  final PlaybackQueue queue;
  final QueuePlayer player;
  final SessionStore session;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: QueuePanel(
          queues: queues,
          playlists: playlists,
          queue: queue,
          player: player,
          session: session,
          onClose: () => context.pop(),
        ),
      ),
    );
  }
}
