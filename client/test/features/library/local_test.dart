import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/features/library/data/local_library.dart';
import 'package:saphire_client/features/library/domain/local_track.dart';
import 'package:saphire_client/features/player/data/player.dart';

/// The bytes an MP3 starts with: an ID3v2 tag, or an MPEG frame header.
const id3Header = [0x49, 0x44, 0x33, 0x04, 0x00];
const frameHeader = [0xFF, 0xFB, 0x64, 0x00];

void main() {
  test('an MP3 is an MP3 by its first bytes', () {
    expect(isMp3(id3Header), true);
    expect(isMp3(frameHeader), true);
    expect(isMp3('not a song'.codeUnits), false);
    expect(isMp3([0xFF]), false);
  });

  test('a valid MP3 is added to the local library', () async {
    final library = LocalLibrary();

    await library.add(name: 'song.mp3', path: '/tmp/song.mp3', bytes: id3Header);

    expect(library.songs.single.title, 'song.mp3');
    expect(library.songs.single.path, '/tmp/song.mp3');
  });

  // The file is not sent to a server here, so this is the only check there is.
  test('a file that is not an MP3 is refused and nothing is stored', () async {
    final library = LocalLibrary();

    expect(
      () => library.add(name: 'notes.txt', path: '/tmp/notes.txt', bytes: 'hello'.codeUnits),
      throwsA(isA<LocalLibraryException>()),
    );
    expect(library.songs, isEmpty);
  });

  test('the library comes back from what was stored', () async {
    final library = LocalLibrary();
    await library.add(name: 'song.mp3', path: '/tmp/song.mp3', bytes: id3Header);

    final again = LocalLibrary();
    for (final row in library.songs.map((song) => song.toJson())) {
      again.songs.add(LocalTrack.fromJson(row));
    }

    expect(again.songs.single.title, 'song.mp3');
  });

  test('a song whose file is gone says so instead of staying quiet', () async {
    final played = <String>[];
    final player = Player((path) async => played.add(path));

    await player.play(LocalTrack(title: 'song.mp3', path: '/tmp/saphire-not-here.mp3'));

    expect(player.error, 'Datei nicht gefunden: song.mp3');
    expect(played, isEmpty);
  });

  test('a song that is on the device is played without a server', () async {
    final file = File('${Directory.systemTemp.path}/saphire-local-test.mp3');
    file.writeAsBytesSync(id3Header);
    addTearDown(() => file.delete());

    final played = <String>[];
    final player = Player((path) async => played.add(path));

    await player.play(LocalTrack(title: 'song.mp3', path: file.path));

    expect(player.error, null);
    expect(played, [file.path]);
  });
}
