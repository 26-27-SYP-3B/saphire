import 'package:flutter/material.dart';

import '../../core/storage/session_store.dart';
import '../../features/playlists/data/playlist_repository.dart';
import '../../features/library/data/local_library.dart';
import '../../features/player/data/queue_repository.dart';
import '../../features/player/domain/player.dart';
import '../../features/player/presentation/player_view.dart';
import '../../features/player/presentation/queue_panel.dart';
import 'nav_bar.dart';
import 'player_bar.dart';
import 'saphire_logo.dart';

/// The frame every signed-in page draws: the mark and the navigation on the left, the page in
/// the middle, the bar at the bottom. The pages look the same because they share this frame, and
/// only what belongs to one page is passed in.
///
/// `child` gets the height left over after the navigation row and the bar, so a page with a long
/// list scrolls inside it instead of pushing the bar off the screen. Below `wideAt` the sidebar
/// has no room and the navigation becomes the row at the bottom, because that is the row a thumb
/// reaches on a phone; `sidebarExtra` is only drawn in the wide layout, because a narrow page has
/// no column to put it in.
///
/// The queue is the column on the right in the wide layout and the whole content area in the
/// narrow one, because a narrow page has no room for a second column. Opening it does not leave
/// the page: the same frame stays, only the middle is the queue, and closing it gives the page
/// back. Nothing here plays or stops anything, so a song keeps playing while the queue is open.
///
/// The same is true for the full player: it is the middle of the frame, and on a phone that
/// middle is the whole page, so opening it is the full-screen player the bar's song is seen in.
/// Closing it gives the page back and the song keeps running.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.selected,
    required this.player,
    required this.queues,
    required this.playlists,
    required this.session,
    required this.child,
    this.localMode = false,
    this.sidebarExtra,
    this.localLibrary,
  });

  final String selected;
  final QueuePlayer player;

  /// What the queue reads and writes, and what the row menu adds a song to.
  final QueueRepository queues;
  final PlaylistRepository playlists;
  final SessionStore session;

  /// What a page shows below the navigation. Nothing for a page that has none.
  final Widget child;

  /// Without a server the queue is the stored one and the songs come from the device.
  final bool localMode;

  /// What a narrow shape means here: rows are taken out by swiping, and there is no column to
  /// put the queue in.
  final LocalLibrary? localLibrary;

  /// What a page shows below the navigation.
  final Widget? sidebarExtra;

  static const double sidebarWidth = 248;
  static const double queueWidth = 360;
  static const double wideAt = 760;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _queueOpen = false;
  bool _playerOpen = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AppShell.wideAt;

        Widget content = widget.child;
        if (_playerOpen) {
          content = PlayerView(
            player: widget.player,
            onQueueOpen: () => setState(() {
              _playerOpen = false;
              _queueOpen = true;
            }),
            onClose: () => setState(() => _playerOpen = false),
          );
        }

        if (_queueOpen) {
          final panel = QueuePanel(
            queues: widget.queues,
            playlists: widget.playlists,
            queue: widget.player.queue,
            player: widget.player,
            session: widget.session,
            localMode: widget.localMode,
            localLibrary: widget.localLibrary,
            phone: !wide,
            onClose: () => setState(() => _queueOpen = false),
          );

          content = wide
            ? Row(
                children: [Expanded(child: content), SizedBox(width: AppShell.queueWidth, child: panel)],
              )
            : panel;
        }

        // On a phone the full player is the whole page, so the bar and the navigation are not
        // drawn under it: a view that shows one song and its controls does not need a copy of the
        // same controls below it.
        final fullscreen = !wide && _playerOpen;

        return Scaffold(
          backgroundColor: scheme.surface,
          body: SafeArea(
            child: Column(
              children: [
                if (wide)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: AppShell.sidebarWidth,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // The lines in the logo asset are thin, so at this size
                                // they come out soft — that is the small mark the mock
                                // shows.
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                                  child: SaphireLogo(size: 44),
                                ),
                                NavBar(selected: widget.selected),
                                ?widget.sidebarExtra,
                              ],
                            ),
                          ),
                        ),
                        Expanded(child: content),
                      ],
                    ),
                  )
                else
                  Expanded(child: content),
                if (!fullscreen)
                  PlayerBar(
                    player: widget.player,
                    localMode: widget.localMode,
                    localLibrary: widget.localLibrary,
                    onQueueOpen: () => setState(() => _queueOpen = true),
                    onPlayerOpen: () => setState(() => _playerOpen = true),
                  ),
                if (!wide && !fullscreen) NavBar(selected: widget.selected, vertical: false),
              ],
            ),
          ),
        );
      },
    );
  }
}
