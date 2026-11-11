import 'package:flutter/material.dart';

import '../../features/library/data/library_repository.dart';
import '../../features/library/data/local_library.dart';
import '../../features/player/data/queue_repository.dart';
import '../../features/player/domain/player.dart';
import 'nav_bar.dart';
import 'player_bar.dart';
import 'saphire_logo.dart';

/// The frame every signed-in page draws: the mark and the navigation on the left, the
/// page in the middle, the bar at the bottom. The pages look the same because they share
/// this frame, and only what belongs to one page is passed in.
///
/// `child` gets the height left over after the navigation row and the bar, so a page with
/// a long list scrolls inside it instead of pushing the bar off the screen. Below `wideAt`
/// the sidebar has no room and the navigation becomes the row at the top; `sidebarExtra`
/// is only drawn in the wide layout, because a narrow page has no column to put it in.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.selected,
    required this.player,
    required this.queues,
    required this.library,
    required this.child,
    this.localMode = false,
    this.sidebarExtra,
    this.localLibrary,
  });

  final String selected;
  final QueuePlayer player;

  /// What the bar's list button opens: the shared queue and the songs it can add.
  final QueueRepository queues;
  final LibraryRepository library;

  /// Without a server the queue is the stored one and the songs come from the device.
  final bool localMode;
  final Widget child;

  /// What the bar starts when no song is open yet: a queue stored on the device. null in a
  /// test that does not care about local mode.
  final LocalLibrary? localLibrary;

  /// What a page shows below the navigation. Nothing for a page that has none.
  final Widget? sidebarExtra;

  static const double sidebarWidth = 248;
  static const double wideAt = 760;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= wideAt;

        return Scaffold(
          backgroundColor: scheme.surface,
          body: SafeArea(
            child: Column(
              children: [
                if (!wide)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: NavBar(selected: selected, vertical: false),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide)
                        SizedBox(
                          width: sidebarWidth,
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
                                NavBar(selected: selected),
                                ?sidebarExtra,
                              ],
                            ),
                          ),
                        ),
                      Expanded(child: child),
                    ],
                  ),
                ),
                PlayerBar(
                  player: player,
                  queues: queues,
                  library: library,
                  localMode: localMode,
                  localLibrary: localLibrary,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
