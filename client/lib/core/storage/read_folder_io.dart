import 'dart:io';
import 'dart:typed_data';

import '../utils/audio_format.dart';
import '../utils/pick_audio.dart';

/// The songs inside a folder, so a whole album can be added in one go. Only the first
/// bytes are read: that is all the format check needs, and the player opens the file by
/// its path anyway.
///
/// Sub-folders are searched too, because a music folder is usually sorted by artist. A
/// sub-folder that cannot be read costs the songs in it, not the rest; a folder that cannot be
/// read at all is an error, because an empty list would say it has no songs, which is a different
/// thing.
Future<List<PickedLocal>> readFolder(String path) async {
  // Read once before anything is swallowed: a folder the app may not read throws here, while an
  // empty list would say the folder has no songs — a different answer to a different problem.
  await Directory(path).list(followLinks: false).isEmpty;

  final files = <File>[];
  // A sub-folder the app may not read must not cost the songs that are readable, and the listing
  // reports one as an error event: without this the walk would stop at it.
  final listing = Directory(path).list(recursive: true, followLinks: false).handleError((Object _) {});
  await for (final item in listing) {
    if (item is File && isAudioFile(item.path)) files.add(item);
    // shortcut: a huge folder is cut off at 500 songs. Upgrade: page the list or read it
    // while the page fills, if anyone ever points this at a whole music drive.
    if (files.length >= 500) break;
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
