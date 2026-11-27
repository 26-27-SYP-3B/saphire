import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/app/theme.dart';
import 'package:saphire_client/core/storage/read_folder.dart';
import 'package:saphire_client/core/storage/session_store.dart';
import 'package:saphire_client/core/storage/settings_store.dart';
import 'package:saphire_client/core/utils/audio_format.dart';
import 'package:saphire_client/features/library/data/library_repository.dart';
import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/library/presentation/library_screen.dart';
import 'package:saphire_client/features/playlists/data/playlist_repository.dart';
import 'package:saphire_client/features/player/data/queue_repository.dart';
import 'package:saphire_client/features/player/domain/player.dart';
import 'package:saphire_client/features/player/domain/queue.dart';
import 'package:saphire_client/features/upload/data/upload_repository.dart';
import 'package:saphire_client/shared/widgets/player_bar.dart';

import '../../support/fake_player.dart';
import '../../support/stub_adapter.dart';

const _music = '/home/nikkas/Musik';

/// The songs of the real music folder with the metadata the app reads from their tags. It is
/// the folder the correction was tested with; a machine without it skips these tests.
Future<LocalLibrary> _loadMusic() async {
  final files = await readFolder(_music);
  final library = LocalLibrary();
  final answers = await library.addAllAsync(files);
  final refused = [
    for (var index = 0; index < answers.length; index++)
      if (answers[index] != null) '${files[index].name}: ${answers[index]}',
  ];
  expect(refused, isEmpty);
  return library;
}

void main() {
  final available = Directory(_music).existsSync();
  final expectedFiles = available
      ? Directory(_music)
            .listSync()
            .whereType<File>()
            .where((file) => isAudioFile(file.path))
            .length
      : 0;

  test(
    'reads title, artist, album, length and cover from the music folder',
    () async {
      final library = await _loadMusic();

      expect(library.tracks, hasLength(expectedFiles));

      final angst = library.tracks.firstWhere(
        (track) => track.title == 'Angst',
      );
      expect(angst.artist, 'Rammstein');
      expect(angst.album, 'Zeit');
      expect(angst.year, 2022);
      expect(angst.durationMs, greaterThan(200000));
      expect(angst.cover, isNotNull);

      // The one m4a in the folder takes the iTunes tags, not only the mp3 ones.
      final kubik = library.tracks.firstWhere(
        (track) => track.title == '50 KUBiK',
      );
      expect(kubik.artist, contains('DJ TÖRKE'));
      expect(kubik.album, '50 KUBiK');
      expect(kubik.cover, isNotNull);

      // Every row has a title; a file without tags keeps its file name.
      expect(
        library.tracks.every((track) => track.title.trim().isNotEmpty),
        isTrue,
      );
    },
    skip: !available,
  );

  testWidgets(
    'the library and the player show the real metadata on desktop and phone',
    (tester) async {
      // A widget test runs in fake async; the isolate and file reads need the real event loop.
      final local = (await tester.runAsync(_loadMusic))!;
      final audio = FakePlayer();
      addTearDown(audio.dispose);
      final session = SessionStore();
      final playlists = PlaylistRepository(
        Dio()..httpClientAdapter = StubAdapter(200, <Object>[]),
        session,
      );
      final queue = PlaybackQueue();
      final player = QueuePlayer(queue: queue, player: audio, session: session);

      tester.view
        ..physicalSize = const Size(1600, 1200)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: LibraryScreen(
            library: LibraryRepository(Dio(), session),
            playlists: playlists,
            queues: QueueRepository(Dio(), session),
            queue: queue,
            player: player,
            uploads: UploadRepository(Dio(), session),
            session: session,
            settings: SettingsStore()..save(localMode: true),
            localLibrary: local,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Search for a song instead of relying on where it happens to sit in a list of 245 rows.
      await tester.enterText(find.byType(TextField).first, 'Angst');
      await tester.pumpAndSettle();

      final list = find.byType(SliverList);
      final row = find.descendant(of: list, matching: find.text('Angst'));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: list, matching: find.text('Rammstein')),
        findsOneWidget,
      );
      expect(find.text('Lokal'), findsWidgets);

      // A cover from the tags is a real image, not the note placeholder.
      expect(find.byType(Image), findsWidgets);

      await tester.tap(row);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Angst'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Rammstein'),
        ),
        findsOneWidget,
      );
      expect(audio.opened.single, contains('Angst.mp3'));

      // The same page at a phone size keeps the title and artist readable.
      tester.view
        ..physicalSize = const Size(420, 900)
        ..devicePixelRatio = 1.0;
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Angst'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Rammstein'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // The binding tears the widget tree down after the test; the fake player's streams are
      // closed by the tear-down below.
    },
    skip: !available,
  );
}
