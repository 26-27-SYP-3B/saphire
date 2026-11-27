import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:saphire_client/core/utils/local_metadata.dart';
import 'package:saphire_client/features/library/data/local_library.dart';

/// A minimal ID3v2.3 tag with a title, an artist and an album, followed by an MP3 frame
/// header. The reader does not need a whole song to read the tags.
Uint8List _taggedMp3() {
  Uint8List frame(String id, String value) {
    final data = <int>[0, ...value.codeUnits];
    return Uint8List.fromList([
      ...id.codeUnits,
      (data.length >> 24) & 0xFF,
      (data.length >> 16) & 0xFF,
      (data.length >> 8) & 0xFF,
      data.length & 0xFF,
      0,
      0,
      ...data,
    ]);
  }

  final frames = <int>[
    ...frame('TIT2', 'Tag Title'),
    ...frame('TPE1', 'Tag Artist'),
    ...frame('TALB', 'Tag Album'),
  ];
  final size = frames.length;

  return Uint8List.fromList([
    0x49, 0x44, 0x33, // "ID3"
    3, 0, 0, // version 2.3, no flags
    (size >> 21) & 0x7F,
    (size >> 14) & 0x7F,
    (size >> 7) & 0x7F,
    size & 0x7F,
    ...frames,
    // One MPEG frame header and some bytes, so the file is recognizably an mp3.
    0xFF, 0xFB, 0x90, 0x64,
    ...List.filled(128, 0),
  ]);
}

void main() {
  test('reads title, artist and album from an mp3 tag', () async {
    final directory = await Directory.systemTemp.createTemp('saphire-tags');
    addTearDown(() => directory.delete(recursive: true));

    final file = File('${directory.path}/tagged.mp3')..writeAsBytesSync(_taggedMp3());
    final metadata = readLocalMetadata(file.path);

    expect(metadata.title, 'Tag Title');
    expect(metadata.artist, 'Tag Artist');
    expect(metadata.album, 'Tag Album');
  });

  test('a local song takes the tags instead of its file name', () async {
    final directory = await Directory.systemTemp.createTemp('saphire-tags');
    addTearDown(() => directory.delete(recursive: true));

    final bytes = _taggedMp3();
    final file = File('${directory.path}/tagged.mp3')..writeAsBytesSync(bytes);
    final library = LocalLibrary();
    final refused = library.add(name: 'tagged.mp3', path: file.path, bytes: bytes);

    expect(refused, isNull);
    expect(library.tracks.single.title, 'Tag Title');
    expect(library.tracks.single.artist, 'Tag Artist');
    expect(library.tracks.single.album, 'Tag Album');
    expect(library.tracks.single.toTrack().isLocal, isTrue);
  });
}
