import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/theme.dart';
import 'package:saphire_client/core/config/api_config.dart';
import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/search/presentation/search_screen.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';
import '../../support/wiring.dart';

const _library = [
  {
    'id': 9.0,
    'title': 'Bohne',
    'artist': 'Anna',
    'album': 'Gemüse',
    'duration_ms': 121000.0,
  },
  {'id': 4.0, 'title': 'Neutrone (Remix)', 'artist': 'Kraftwerk'},
];

const _queue = [
  {
    'position': 1.0,
    'track_id': 9.0,
    'title': 'Bohne',
    'artist': 'Anna',
    'duration_ms': 121000.0,
  },
];

Future<Wiring> openSearch(
  WidgetTester tester, {
  LocalLibrary? local,
  FakePlayer? audio,
}) async {
  tester.view..physicalSize = const Size(1200, 900)..devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final wiring = Wiring(
    loggedIn(),
    libraryAdapter: StubAdapter(200, _library),
    playlistAdapter: StubAdapter(200, <Object>[]),
    queueAdapter: StubAdapter(200, _queue),
    audio: audio,
  );
  addTearDown(wiring.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      home: SearchScreen(
        library: wiring.library,
        playlists: wiring.playlists,
        queues: wiring.queues,
        queue: wiring.queue,
        player: wiring.player,
        session: wiring.session,
        localLibrary: local ?? LocalLibrary(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return wiring;
}

void main() {
  testWidgets('a search finds a server song by its artist and plays it', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    await openSearch(tester, audio: audio);

    await tester.enterText(find.byType(TextField), 'ann');
    await tester.pumpAndSettle();

    expect(find.text('Bohne'), findsOneWidget);
    expect(find.text('Neutrone (Remix)'), findsNothing);

    await tester.tap(find.text('Bohne'));
    await tester.pumpAndSettle();

    expect(audio.opened, ['$apiBaseUrl/api/music/9']);
  });

  testWidgets('a search finds a local song and plays its file', (tester) async {
    final audio = FakePlayer();
    addTearDown(audio.dispose);
    final local = LocalLibrary();
    local.add(name: 'lokal.mp3', bytes: Uint8List.fromList([0x49, 0x44, 0x33]));

    await openSearch(tester, audio: audio, local: local);
    await tester.enterText(find.byType(TextField), 'lokal');
    await tester.pumpAndSettle();

    expect(find.text('lokal.mp3'), findsOneWidget);
    await tester.tap(find.text('lokal.mp3'));
    await tester.pumpAndSettle();

    expect(audio.opened.single, startsWith('data:audio/mpeg'));
  });

  testWidgets('nothing found says so instead of showing the whole library', (tester) async {
    await openSearch(tester);
    await tester.enterText(find.byType(TextField), 'xyz');
    await tester.pumpAndSettle();

    expect(find.text('Keine Songs gefunden.'), findsOneWidget);
  });
}
