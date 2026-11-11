import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../storage/read_folder.dart';

/// A picked song: the name the server would store as the title and its bytes.
typedef PickedAudio = ({String name, Uint8List bytes});
typedef PickAudio = Future<List<PickedAudio>?> Function();

/// The picker every screen that adds a song uses. A widget test passes its own,
/// because the plugin cannot answer there. Any file can be picked, because which
/// formats are allowed is the server's decision (see server/music.go); a file it
/// refuses comes back as its message and is shown for that file.
Future<List<PickedAudio>?> pickAudioFiles() async {
  final picked = await FilePicker.pickFiles(type: FileType.any);
  if (picked.isEmpty) return null;

  // shortcut: the whole file is held in memory. Upgrade: stream from the path on
  // the platforms that give one, so a 500 MiB song is not read twice.
  return [for (final file in picked) (name: file.name, bytes: await file.readAsBytes())];
}

/// A picked file for the local library: the bytes to check the format and, on a device,
/// the path that survives a restart. A browser gives no path.
typedef PickedLocal = ({String name, String? path, Uint8List? bytes});
typedef PickLocalAudio = Future<List<PickedLocal>?> Function();

Future<List<PickedLocal>?> pickLocalAudioFiles() async {
  final picked = await FilePicker.pickFiles(type: FileType.any);
  if (picked.isEmpty) return null;

  return [for (final file in picked) (name: file.name, path: file.path, bytes: await file.readAsBytes())];
}

/// A whole folder for the local library, one entry per song in it. Null when the picker
/// was cancelled.
Future<List<PickedLocal>?> pickLocalFolder() async {
  final path = await FilePicker.getDirectoryPath();
  if (path == null) return null;

  return readFolder(path);
}
