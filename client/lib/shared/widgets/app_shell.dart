import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/storage/session_store.dart';

import '../../features/library/data/library_repository.dart';
import '../../features/library/data/local_library.dart';
import '../../features/player/data/queue_repository.dart';
import '../../features/player/domain/player.dart';
import '../../features/player/presentation/player_view.dart';
import '../../features/player/presentation/queue_panel.dart';
import '../../features/playlists/data/playlist_repository.dart';
import '../../features/playlists/domain/playlist.dart';
import 'library_sidebar.dart';
import 'nav_bar.dart';
import 'player_bar.dart';
import 'saphire_logo.dart';

/// The frame every signed-in page draws: the navigation (a sidebar on a wide window, the row at
/// the bottom of a phone), the page in the middle, the queue on the right where there is room,
/// and the player at the bottom.
///
/// The frame is the only place that knows the shapes. A page only hands in its content and, if
/// it already read them, its playlists for the sidebar; it does not draw a navigation or a
/// player of its own, so two pages cannot disagree about what is playing.
///
/// The queue is the right column on a desktop and a drop-up over the page on a phone, because a
/// narrow page has no room for a second column. Opening it does not leave the page: the frame
/// stays, the queue only comes in front of it, and closing it gives the page back. Nothing here
/// plays or stops anything, so a song keeps playing while the queue is open.
///
/// The full player is the middle of the frame. On a phone that middle is the whole page, so
/// opening it is the full-screen player; closing it gives the page back and the song keeps
/// running.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.selected,
    required this.player,
    required this.queues,
    required this.playlists,
    required this.library,
    required this.session,
    required this.child,
    this.localMode = false,
    this.sidebarExtra,
    this.localLibrary,
    this.sidebarPlaylists = const [],
  });

  final String selected;
  final QueuePlayer player;

  /// What the queue reads and writes, and what the row menu adds a song to.
  final QueueRepository queues;
  final PlaylistRepository playlists;

  /// What the queue's search offers when no playlist is playing.
  final LibraryRepository library;
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

  /// The playlists a page already read, shown in the desktop sidebar. A page that has not read
  /// them hands in nothing and the sidebar simply lists no server playlist.
  final List<Playlist> sidebarPlaylists;

  static const double sidebarWidth = 248;
  static const double queueWidth = 360;
  static const double wideAt = 800;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _queueOpen = false;
  bool _playerOpen = false;
  double _sidebarWidth = AppShell.sidebarWidth;

  void _togglePlay() {
    if (widget.player.playing) {
      widget.player.pause();
    } else if (widget.player.queue.current != null ||
        widget.player.localCurrent != null) {
      widget.player.resume();
    } else if (!widget.player.queue.isEmpty) {
      widget.player.playCurrent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final localLibrary = widget.localLibrary ?? LocalLibrary();

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
            library: widget.library,
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
                  children: [
                    Expanded(child: content),
                    SizedBox(width: AppShell.queueWidth, child: panel),
                  ],
                )
              // A drop-up, not a page: it covers the lower part of what the person was looking
              // at, so the page stays where it was and closing it costs no navigation. The bar
              // below stays visible, because the queue and the bar are the same song.
              : Stack(
                  children: [
                    content,
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: constraints.maxHeight * 0.62,
                        ),
                        child: SizedBox(
                          width: double.infinity,
                          child: Material(
                            color: scheme.surface,
                            elevation: 8,
                            clipBehavior: Clip.antiAlias,
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(20),
                            ),
                            child: panel,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
        }

        // On a phone the full player is the whole page, so the bar and the navigation are not
        // drawn under it: a view that shows one song and its controls does not need a copy of the
        // same controls below it.
        final fullscreen = !wide && _playerOpen;

        final body = Scaffold(
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
                          width: _sidebarWidth,
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    16,
                                    16,
                                    12,
                                  ),
                                  child: SaphireLogo(size: 44),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  child: NavBar(selected: widget.selected),
                                ),
                                LibrarySidebar(
                                  playlists: widget.sidebarPlaylists,
                                  localLibrary: localLibrary,
                                  localMode: widget.localMode,
                                ),
                                ?widget.sidebarExtra,
                              ],
                            ),
                          ),
                        ),
                        // The sidebar is as wide as the person makes it; this is the grip that
                        // changes it. A hovered row is the shape a desktop app uses to show that
                        // the pointer is on something.
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeColumn,
                          child: GestureDetector(
                            onHorizontalDragUpdate: (details) => setState(() {
                              _sidebarWidth = (_sidebarWidth + details.delta.dx)
                                  .clamp(200.0, 380.0);
                            }),
                            child: Container(
                              width: 6,
                              color: Colors.transparent,
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
                    onQueueOpen: () => setState(() {
                      // The side panel and the full player cannot share the middle on a narrow
                      // window: the queue would squeeze the player below its controls. Opening
                      // the queue from the bar therefore closes the player first.
                      _playerOpen = false;
                      _queueOpen = !_queueOpen;
                    }),
                    onPlayerOpen: () => setState(() {
                      _playerOpen = true;
                      // The full player is the whole page on a phone; a queue sheet floating over
                      // it would cover the controls it was opened for.
                      _queueOpen = false;
                    }),
                  ),
                if (!wide && !fullscreen)
                  NavBar(selected: widget.selected, vertical: false),
              ],
            ),
          ),
        );

        // Space is what a desktop player uses for play/pause. A focused text field handles the
        // key itself, so typing a space in a search field does not start a song.
        return Focus(
          autofocus: true,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.space): _togglePlay,
            },
            child: body,
          ),
        );
      },
    );
  }
}
