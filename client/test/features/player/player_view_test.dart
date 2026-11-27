import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/features/library/domain/local_track.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';
import 'package:saphire_client/features/player/presentation/player_view.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

// Two songs, so a test can watch the player move away from one and back to it.
const queueAnswer = [
  {
    'position': 1.0,
    'track_id': 8.0,
    'title': 'Technogal.mp3',
    'artist': 'Kraftwerk',
    'duration_ms': 174000.0,
    'waveform': [0.0, 128.0, 255.0],
  },
  {
    'position': 2.0,
    'track_id': 4.0,
    'title': 'lied.wav',
    'artist': '',
    'duration_ms': 0.0,
  },
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
  Size size = const Size(420, 900),
}) async {
  // A phone-shaped window, below AppShell.wideAt, so the view is measured as a phone shows it.
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = session ?? loggedIn();
  // A test that does not look at the queue still needs the player to exist; the default answers an
  // empty queue, because a real Dio here would be a request to a server that is not there.
  final wiring = Wiring(
    store,
    queueAdapter: StubAdapter(200, <Object>[]),
    audio: audio,
  );
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
  testWidgets('tapping the bar asks the frame for the full player', (
    tester,
  ) async {
    var opened = false;
    final wiring = Wiring(
      loggedIn(),
      queueAdapter: StubAdapter(200, <Object>[]),
    );
    addTearDown(wiring.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerBar(
            player: wiring.player,
            onPlayerOpen: () => opened = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The song's text is in the bar's own InkWell; the controls in the middle are buttons of
    // their own, so the text is the part that opens the player.
    await tester.tap(find.text('Nichts wird abgespielt'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });

  // The bar is visible on every page, so the running time and the length have to be there too,
  // not only in the full player.
  testWidgets('the bar shows the running time and the length', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final wiring = Wiring(
      loggedIn(),
      queueAdapter: StubAdapter(200, <Object>[]),
      audio: audio,
    );
    addTearDown(wiring.dispose);

    wiring.queue.fill([
      QueueEntry(
        position: 1,
        trackId: 8,
        title: 'Technogal.mp3',
        artist: 'Kraftwerk',
      ),
    ]);
    await wiring.player.playCurrent();
    audio.length(const Duration(seconds: 30));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlayerBar(player: wiring.player)),
      ),
    );
    await tester.pump();

    // The desktop bar shows the two clocks on either side of the progress bar, the way
    // Spotify does, instead of one combined label.
    audio.at(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(find.text('0:10'), findsOneWidget);
    expect(find.text('0:30'), findsOneWidget);

    audio.at(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(find.text('0:11'), findsOneWidget);
  });

  // A 320 dp phone is the narrowest shape the transport has to fit. The queue button and the
  // three transport buttons may not push the play button off the card.
  testWidgets('the player fits a small phone', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = await openPlayer(
      tester,
      audio: audio,
      size: const Size(320, 568),
      prep: (wiring) async {
        wiring.queue.fill([
          QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
        ]);
        await wiring.player.playCurrent();
        audio.length(const Duration(seconds: 30));
      },
    );

    expect(wiring.queue.current?.trackId, 8);
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  // A landscape phone is wide but short. The card scrolls instead of clipping the controls.
  testWidgets('the player scrolls in a short landscape window', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    await openPlayer(
      tester,
      audio: audio,
      size: const Size(851, 393),
      prep: (wiring) async {
        wiring.queue.fill([
          QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
        ]);
        await wiring.player.playCurrent();
        audio.length(const Duration(seconds: 30));
      },
    );

    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.byTooltip('Warteschlange'), findsOneWidget);
  });

  // The ten-second jumps and the volume slider belong to the desktop bar, not to the phone
  // player.
  testWidgets('the phone player has no ten-second or volume controls', (
    tester,
  ) async {
    await openPlayer(tester);

    expect(find.byIcon(Icons.replay_10), findsNothing);
    expect(find.byIcon(Icons.forward_10), findsNothing);
    expect(find.byTooltip('Stumm'), findsNothing);
  });

  testWidgets(
    'the player shows the song it is at and its controls move the player',
    (tester) async {
      final audio = FakePlayer();
      addTearDown(audio.dispose);

      final wiring = await openPlayer(
        tester,
        audio: audio,
        prep: (wiring) async {
          wiring.queue.fill(
            queueAnswer
                .map(
                  (entry) => QueueEntry.fromJson(entry.cast<String, dynamic>()),
                )
                .toList(),
          );
          await wiring.player.playCurrent();
          // The jump buttons are only on for a song the player knows the length of.
          audio.length(const Duration(seconds: 30));
          audio.at(const Duration(seconds: 10));
        },
      );

      expect(find.text('Technogal.mp3'), findsOneWidget);
      // The queue answer names the artist the file's tags named, so the player shows it under the
      // title instead of the slot number.
      expect(find.text('Kraftwerk'), findsOneWidget);

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
    },
  );

  // Swiping down leaves the view. Nothing here stops the audio, so the song keeps running and the
  // bar still names it.
  testWidgets('swiping down closes the view without interrupting playback', (
    tester,
  ) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    var closed = false;
    await openPlayer(
      tester,
      audio: audio,
      onClose: () => closed = true,
      prep: (wiring) async {
        wiring.queue.fill([
          QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
        ]);
        await wiring.player.playCurrent();
      },
    );

    await tester.fling(find.byType(Dismissible), const Offset(0, 300), 800);
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(audio.stopped, isEmpty);
    expect(audio.playing, isTrue);
  });

  testWidgets('the queue button opens the queue inside the player', (
    tester,
  ) async {
    var opened = false;
    await openPlayer(tester, onQueueOpen: () => opened = true);

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    expect(find.text('Warteschlange'), findsWidgets);
    expect(find.text('0 Titel'), findsOneWidget);

    // The full panel is one tap away, but the song keeps playing in this view.
    await tester.tap(find.byTooltip('Warteschlange bearbeiten'));
    await tester.pumpAndSettle();

    expect(opened, isTrue);
  });

  // The compact queue shows what a listener needs while the song runs: the order, the artist
  // and the length. A row starts its song.
  testWidgets('the compact queue shows the order and plays a row', (
    tester,
  ) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = await openPlayer(
      tester,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(
          queueAnswer
              .map(
                (entry) => QueueEntry.fromJson(entry.cast<String, dynamic>()),
              )
              .toList(),
        );
        await wiring.player.playCurrent();
      },
    );

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    expect(find.text('2 Titel'), findsOneWidget);
    // One artist under the title, one in the queue row.
    expect(find.text('Kraftwerk'), findsNWidgets(2));
    expect(find.text('2:54'), findsOneWidget);

    await tester.tap(find.text('lied.wav'));
    await tester.pumpAndSettle();

    expect(wiring.queue.current?.title, 'lied.wav');
    expect(audio.opened.last, '$apiBaseUrl/api/music/4');
    // The second song has no artist tag, so only its queue row still names the first one.
    expect(find.text('Kraftwerk'), findsOneWidget);
  });

  // A device list is its own queue; the sheet must not claim it is empty while a file plays.
  testWidgets('the compact queue shows the device list', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    await openPlayer(
      tester,
      audio: audio,
      prep: (wiring) async {
        await wiring.player.playLocalQueue([
          LocalTrack(title: 'a.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
          LocalTrack(title: 'b.mp3', bytes: Uint8List.fromList([0xFF, 0xFB])),
        ]);
      },
    );

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    expect(find.text('2 Titel'), findsOneWidget);
    expect(find.text('a.mp3'), findsWidgets);
    expect(find.text('b.mp3'), findsOneWidget);

    await tester.tap(find.text('b.mp3'));
    await tester.pumpAndSettle();

    expect(find.text('b.mp3'), findsWidgets);
  });

  // The sheet sits over the cover, not over the seek bar, so a tap on the bar still seeks.
  testWidgets('the seek bar works while the queue sheet is open', (
    tester,
  ) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    await openPlayer(
      tester,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill([
          QueueEntry(position: 1, trackId: 8, title: 'Technogal.mp3'),
        ]);
        await wiring.player.playCurrent();
        audio.length(const Duration(seconds: 30));
        audio.at(const Duration(seconds: 10));
      },
    );

    await tester.tap(find.byTooltip('Warteschlange'));
    await tester.pumpAndSettle();

    final bar = find.byType(Slider).first;
    await tester.tapAt(tester.getCenter(bar) + const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(audio.sought, isNotEmpty);
  });

  // Without a song there is nothing to play or move, so the controls are off and a tap on one of
  // them cannot claim a jump it did not do.
  testWidgets('with no song open the controls are off', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    await openPlayer(tester, audio: audio);

    expect(find.text('Nichts wird abgespielt'), findsOneWidget);

    for (final tooltip in [
      'Wiedergeben',
      'Vorheriges Lied',
      'Nächstes Lied',
      'Wiederholen',
      'Zufällige Wiedergabe',
    ]) {
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip(tooltip),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
    }

    expect(audio.played, isEmpty);
    expect(audio.sought, isEmpty);
    expect(audio.volumes, isEmpty);
  });

  // The two ways a song does not simply move on belong to the player the page shows: a control
  // that only changed a local switch would not change what the next song is.
  testWidgets('repeat and shuffle reach the player', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    final wiring = await openPlayer(
      tester,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(
          queueAnswer
              .map(
                (entry) => QueueEntry.fromJson(entry.cast<String, dynamic>()),
              )
              .toList(),
        );
        await wiring.player.playCurrent();
        audio.length(const Duration(seconds: 30));
      },
    );

    await tester.tap(find.byTooltip('Wiederholen'));
    await tester.pumpAndSettle();
    expect(wiring.player.repeatOne, isTrue);

    await tester.tap(find.byTooltip('Zufällige Wiedergabe'));
    await tester.pumpAndSettle();
    expect(wiring.player.shuffle, isTrue);
  });

  // The progress bar is the other way to seek: a press on it moves the label to the target while
  // the finger is down, and the release is what tells the player where to go.
  testWidgets('the progress bar moves the song to where it was tapped', (
    tester,
  ) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);

    await openPlayer(
      tester,
      audio: audio,
      prep: (wiring) async {
        wiring.queue.fill(
          queueAnswer
              .map(
                (entry) => QueueEntry.fromJson(entry.cast<String, dynamic>()),
              )
              .toList(),
        );
        await wiring.player.playCurrent();
        audio.length(const Duration(seconds: 30));
        audio.at(const Duration(seconds: 10));
      },
    );

    final bar = find.byType(Slider).first;
    await tester.tapAt(tester.getCenter(bar) + const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(audio.sought, isNotEmpty);
    expect(audio.sought.last, greaterThan(const Duration(seconds: 10)));
    // The label follows the released position, not the old one.
    expect(find.text('0:10'), findsNothing);
  });
}
