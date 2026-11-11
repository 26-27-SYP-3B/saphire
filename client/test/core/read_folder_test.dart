import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/storage/read_folder.dart';

void main() {
  test('a folder is read as its songs, with the first bytes of each', () async {
    final dir = Directory.systemTemp.createTempSync('saphire-folder');
    addTearDown(() => dir.deleteSync(recursive: true));

    File('${dir.path}${Platform.pathSeparator}a.mp3').writeAsBytesSync([0xFF, 0xFB, 0x00]);
    File('${dir.path}${Platform.pathSeparator}notes.txt').writeAsStringSync('kein Lied');
    Directory('${dir.path}${Platform.pathSeparator}cd').createSync();
    File('${dir.path}${Platform.pathSeparator}cd${Platform.pathSeparator}b.MP3')
        .writeAsBytesSync([0x49, 0x44, 0x33]);

    final songs = await readFolder(dir.path);

    // Only the songs, sub-folders included, in a fixed order; the text file is not one.
    expect(songs.map((song) => song.name), ['a.mp3', 'b.MP3']);
    expect(songs.first.path, endsWith('a.mp3'));
    // The format check only needs the start of the file.
    expect(songs.first.bytes, [0xFF, 0xFB, 0x00]);
  });
}
