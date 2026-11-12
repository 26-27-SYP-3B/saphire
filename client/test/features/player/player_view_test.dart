import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';
import 'package:saphire_client/features/player/presentation/player_view.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

// Two songs, so a test can watch the player move away from one and back to it.
const queueAnswer = [
  {'position': 1.0, 'track_id': 8.0, 'title': 'Technogal.mp3'},
  {'position': 2.0, 'track_id': 4.0, 'title': 'lied.wav'},
];

/// Pumps the full player the way AppShell draws it on a phone, with a valid session. The view is
/// what these tests are about, so it is pumped on its own; the callbacks are what the frame passes
/// it, so a test can see that the view asked for the queue or for closing.
///
/// `prep` runs before the view opens. Which song this device is at and how long it is are things a
/// test needs to say first, because the buttons are only on when the player is at a song with a
/// length.
Future<Wiring> openPlayer(
  WidgetTester tester, {
  SongPlayer? audio,
  SessionStore? session,
  VoidCallback? onClose,
  VoidCallback? onQueueOpen,
  Future<void> Function(Wiring wiring)? prep,
}) async {
  // A phone-shaped window, below AppShell.wideAt, so the view is measured as a phone shows it.
  tester.view..physicalSize = const Size(420, 900)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = session ?? loggedIn();
  // A test that does not look at the queue still needs the player to exist; the default answers an
  // empty queue, because a real Dio here would be a request to a server that is not there.
  final wiring = Wiring(store, queueAdapter: StubAdapter(200, <Object>[]), audio: audio);
  addTearDown(wiring.dispose);

  if (prep != null) await prep(wiring);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlayerView(
          player: wiring.player,
          onQueueOpen: onQueueOpen,
          onClose: onClose,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  return wiring;
}

void main() {
  // Tapping the bar is what opens this view, so the bar has to say that to the frame.
  testWidgets('tapping the bar asks the frame for the full player', (tester) async {
    var opened = false;
    final wiring = Wiring(loggedIn(), queueAdapter: StubAdapter(200, <Object>[]));
    addTearDown(wiring.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerBar(player: wiring.player, onPlayerOpen: () => opened = true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The bar's own InkWell is the one around its text; the buttons inside it are InkWell too.
    await tester.tap(find.ancestor(of: find.text('Nichts wird abgespielt'), matching: find.byType(InkWell)));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });

  testWidgets('the player shows the song it is at and its controls move the player', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = await openPlayer(
      tester,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(queueAnswer.map((entry) => QueueEntry.fromJson(entry.cast<String, dynamic>())).toList());
        await wiring.player.playCurrent();
        // The jump buttons are only on for a song the player knows the length of.
        audio.length(const Duration(seconds: 30));
        audio.at(const Duration(seconds: 10));
      },
    );

    expect(find.text('Technogal.mp3'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pumpAndSettle();
    expect(audio.playing, isFalse);

    // The buttons move the same player the bar moves: away from the song and back to it.
    await tester.tap(find.byTooltip('Nächstes Lied'));
    await tester.pumpAndSettle();
    expect(wiring.queue.current?.title, 'lied.wav');

    await tester.tap(find.byTooltip('Vorheriges Lied'));
    await tester.pumpAndSettle();
    expect(wiring.queue.current?.title, 'Technogal.mp3');

    // The ten-second buttons jump from where the song is, not from its start.
    await tester.tap(find.byTooltip('10 Sekunden vor'));
    await tester.pumpAndSettle();
    expect(audio.sought, [const Duration(seconds: 20)]);

    await tester.tap(find.byTooltip('10 Sekunden zurück'));
    await tester.pumpAndSettle();
    expect(audio.sought.last, const Duration(seconds: 10));

    // The second slider is the volume; the first is the progress bar. Dragging left from the
    // middle of it is the only way to change a value that starts at its top.
    await tester.drag(find.byType(Slider).last, const Offset(-100, 0));
    await tester.pumpAndSettle();

    expect(audio.volumes, isNotEmpty);
    expect(audio.volumes.last, lessThan(1.0));
  });

  // Swiping down leaves the view. Nothing here stops the audio, so the song keeps running and the
  // bar still names it.
  testWidgets('swiping down closes the view without interrupting playback', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    var closed = false;
    await openPlayer(
      tester,
      audio: audio,
      onClose: () => closed = true,
      prep: (wiring) async {
        wiring.queue.fill([QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3')]);
        await wiring.player.playCurrent();
      },
    );

    await tester.fling(find.byType(Dismissible), const Offset(0, 300), 800);
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(audio.stopped, isEmpty);
    expect(audio.playing, isTrue);
  });

  testWidgets('the queue button inside the player asks the frame for the queue', (tester) async {
    var opened = false;
    await openPlayer(tester, onQueueOpen: () => opened = true);

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });

  // Without a song there is nothing to play or move, so the controls are off and a tap on one of
  // them cannot claim a jump it did not do.
  testWidgets('with no song open the controls are off', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    await openPlayer(tester, audio: audio);

    expect(find.text('Nichts wird abgespielt'), findsOneWidget);

    for (final tooltip in ['Wiedergeben', 'Vorheriges Lied', 'Nächstes Lied', '10 Sekunden vor', '10 Sekunden zurück']) {
      expect(
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton))).onPressed,
        isNull,
      );
    }

    expect(audio.played, isEmpty);
    expect(audio.sought, isEmpty);
    expect(audio.volumes, isEmpty);
  });
}
