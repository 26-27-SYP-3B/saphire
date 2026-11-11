import 'dart:io';
import 'dart:typed_data';

import '../utils/pick_audio.dart';

/// The songs inside a folder, so a whole album can be added in one go. Only the first
/// bytes are read: that is all the format check needs, and the player opens the file by
/// its path anyway.
///
/// Sub-folders are searched too, because a music folder is usually sorted by artist. A
/// file that cannot be read is left out rather than failing the whole folder.
Future<List<PickedLocal>> readFolder(String path) async {
  final files = <File>[];
  try {
    await for (final item in Directory(path).list(recursive: true, followLinks: false)) {
      if (item is File && item.path.toLowerCase().endsWith('.mp3')) files.add(item);
      // shortcut: a huge folder is cut off at 500 songs. Upgrade: page the list or read it
      // while the page fills, if anyone ever points this at a whole music drive.
      if (files.length >= 500) break;
    }
  } on FileSystemException {
    // A sub-folder the app may not read must not cost the songs that are readable.
  }
  files.sort((a, b) => a.path.compareTo(b.path));

  final songs = <PickedLocal>[];
  for (final file in files) {
    try {
      songs.add((name: file.uri.pathSegments.last, path: file.path, bytes: await _firstBytes(file)));
    } on FileSystemException {
      // A file that vanished between the listing and the read is not a song this folder
      // still has.
    }
  }
  return songs;
}

Future<Uint8List> _firstBytes(File file) async {
  final bytes = <int>[];
  await for (final chunk in file.openRead(0, 12)) {
    bytes.addAll(chunk);
  }
  return Uint8List.fromList(bytes);
}
