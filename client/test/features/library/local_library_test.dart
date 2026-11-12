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

    expect(refused, 'nur Audiodateien werden übernommen');
    expect(library.tracks, isEmpty);
  });

  // A folder of songs is not a folder of MP3s: the other formats are songs too.
  test('an audio file that is not an MP3 lands in the library', () {
    final library = LocalLibrary();

    final refused = library.add(name: 'song.flac', path: '/music/song.flac', bytes: Uint8List.fromList([0x66, 0x4C, 0x61, 0x43]));

    expect(refused, null);
    expect(library.tracks.single.title, 'song.flac');
  });

  // A picture renamed to .mp3 would pass on the name alone.
  test('an MP3 name over other bytes is refused', () {
    final library = LocalLibrary();

    final refused = library.add(name: 'fake.mp3', bytes: Uint8List.fromList([0x4D, 0x5A, 0x90, 0x00]));

    expect(refused, 'die Datei ist keine gültige Audiodatei');
    expect(library.tracks, isEmpty);
  });

  // The same is true under another audio name: an image is not a song whatever it is called.
  test('an audio name over a picture is refused', () {
    final library = LocalLibrary();

    final refused = library.add(name: 'fake.flac', bytes: Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0]));

    expect(refused, 'die Datei ist keine gültige Audiodatei');
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

  // A folder import adds the same list twice easily, so a file that is already there is
  // not added again. The same name in another folder is another song.
  test('the same file is only in the library once', () {
    final library = LocalLibrary();

    expect(library.add(name: 'song.mp3', path: '/music/song.mp3', bytes: id3Mp3()), null);
    expect(
      library.add(name: 'song.mp3', path: '/music/song.mp3', bytes: id3Mp3()),
      'ist schon in der Bibliothek',
    );
    expect(library.tracks, hasLength(1));

    expect(library.add(name: 'song.mp3', path: '/music/live/song.mp3', bytes: id3Mp3()), null);
    expect(library.tracks, hasLength(2));
  });

  // A local playlist and the local queue are on the device, so they have to come back
  // after a restart without any server.
  test('a local playlist and the queue survive a restart', () async {
    useEmptyStorage();

    final library = LocalLibrary(FlutterSecureStorage())
      ..add(name: 'song.mp3', path: '/music/song.mp3', bytes: id3Mp3());
    final playlist = library.createPlaylist('Favoriten')!;
    library.addToPlaylist(playlist, library.tracks.single);
    library.addToQueue(library.tracks.single);
    await Future<void>.delayed(Duration.zero);

    final restored = await LocalLibrary.restore();

    expect(restored.playlists, hasLength(1));
    expect(restored.playlists.single.name, 'Favoriten');
    expect(restored.playlists.single.songs.single.title, 'song.mp3');
    expect(restored.playlists.single.songs.single.path, '/music/song.mp3');
    expect(restored.queue.single.path, '/music/song.mp3');
  });

  // A pick in a browser has bytes only. Storing its title alone would restore a row that
  // can never be opened, so it stays a song for this session.
  test('a browser pick without a path does not come back as a broken row', () async {
    useEmptyStorage();

    LocalLibrary(FlutterSecureStorage()).add(name: 'kauf.mp3', bytes: id3Mp3());
    await Future<void>.delayed(Duration.zero);

    final restored = await LocalLibrary.restore();

    expect(restored.tracks, isEmpty);
  });

  // An older version stored such a row with path: null. Restoring it would show a song
  // that always fails, so the read side drops it too.
  test('a stored row without a path is dropped on restore', () async {
    FlutterSecureStorage.setMockInitialValues({
      'local_library': '[{"title":"kauf.mp3","path":null}]',
    });

    final restored = await LocalLibrary.restore();

    expect(restored.tracks, isEmpty);
  });

  // Two playlists with the same name would be indistinguishable in the list, and an
  // empty one has nothing to open. Both are refused instead of saved with a suffix.
  test('an empty or duplicate playlist name is refused', () {
    final library = LocalLibrary();

    expect(library.createPlaylist('   '), null);
    expect(library.createPlaylist('Favoriten'), isNotNull);
    expect(library.createPlaylist('Favoriten'), null);
    expect(library.playlists, hasLength(1));
  });
}
