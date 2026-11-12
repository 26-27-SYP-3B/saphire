import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/read_folder.dart';

void main() {
  test('a folder is read as its songs, with the first bytes of each', () async {
    final dir = Directory.systemTemp.createTempSync('saphire-folder');
    addTearDown(() => dir.deleteSync(recursive: true));

    File('${dir.path}${Platform.pathSeparator}a.mp3').writeAsBytesSync([0xFF, 0xFB, 0x00]);
    // A folder of songs is not a folder of MP3s only: every audio format counts.
    File('${dir.path}${Platform.pathSeparator}b.m4a').writeAsBytesSync([0x00, 0x00, 0x00, 0x20]);
    File('${dir.path}${Platform.pathSeparator}notes.txt').writeAsStringSync('kein Lied');
    Directory('${dir.path}${Platform.pathSeparator}cd').createSync();
    File('${dir.path}${Platform.pathSeparator}cd${Platform.pathSeparator}c.MP3')
        .writeAsBytesSync([0x49, 0x44, 0x33]);

    final songs = await readFolder(dir.path);

    // Only the songs, sub-folders included, in a fixed order; the text file is not one.
    expect(songs.map((song) => song.name), ['a.mp3', 'b.m4a', 'c.MP3']);
    expect(songs.first.path, endsWith('a.mp3'));
    // The format check only needs the start of the file.
    expect(songs.first.bytes, [0xFF, 0xFB, 0x00]);
  });

  // A phone gives the app no access to most folders. That is not "this folder has no songs", so
  // it must not be answered with an empty list.
  test('a folder that cannot be read is an error, not an empty folder', () async {
    final missing = '${Directory.systemTemp.path}${Platform.pathSeparator}kein-solcher-ordner';

    expect(() => readFolder(missing), throwsA(isA<FileSystemException>()));
  });
}
