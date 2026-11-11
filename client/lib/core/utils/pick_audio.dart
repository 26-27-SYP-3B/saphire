import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

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
