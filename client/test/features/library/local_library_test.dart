import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/features/library/data/local_library.dart';

/// An MP3 starts with an ID3 tag, the way every file from a store does.
Uint8List id3Mp3() => Uint8List.fromList([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0]);

/// A file without the tag still starts with a frame header.
Uint8List frameMp3() => Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, 0, 0, 0, 0]);

void useEmptyStorage() => FlutterSecureStorage.setMockInitialValues({});

void main() {
  test('an MP3 from a device lands in the library with its path', () {
    final library = LocalLibrary();

    final refused = library.add(name: 'song.mp3', path: '/music/song.mp3', bytes: id3Mp3());

    expect(refused, null);
    expect(library.tracks, hasLength(1));
    expect(library.tracks.single.title, 'song.mp3');
    expect(library.tracks.single.path, '/music/song.mp3');
  });

  test('a file with another name is refused', () {
    final library = LocalLibrary();

    final refused = library.add(name: 'notes.txt', bytes: id3Mp3());

    expect(refused, 'nur MP3-Dateien werden übernommen');
    expect(library.tracks, isEmpty);
  });

  // A picture renamed to .mp3 would pass on the name alone.
  test('an MP3 name over other bytes is refused', () {
    final library = LocalLibrary();

    final refused = library.add(name: 'fake.mp3', bytes: Uint8List.fromList([0x4D, 0x5A, 0x90, 0x00]));

    expect(refused, 'die Datei ist keine gültige MP3-Datei');
    expect(library.tracks, isEmpty);
  });

  test('the frame header of a file without a tag is enough', () {
    expect(LocalLibrary().isMp3(frameMp3()), true);
  });

  // The library keeps the path, not the file: a song must not be copied into the store.
  test('title and path survive a restart, the bytes do not', () async {
    useEmptyStorage();

    LocalLibrary(FlutterSecureStorage()).add(name: 'song.mp3', path: '/music/song.mp3', bytes: id3Mp3());
    await Future<void>.delayed(Duration.zero);

    final restored = await LocalLibrary.restore();

    expect(restored.tracks, hasLength(1));
    expect(restored.tracks.single.title, 'song.mp3');
    expect(restored.tracks.single.path, '/music/song.mp3');
    expect(restored.tracks.single.bytes, null);
  });
}
