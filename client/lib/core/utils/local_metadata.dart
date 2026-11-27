import 'dart:typed_data';

export 'local_metadata_stub.dart' if (dart.library.io) 'local_metadata_io.dart';

/// What the tags of a local file say. Read once when the song is added; the values are stored
/// with the song, so a page does not parse the file again.
typedef LocalAudioMetadata = ({
  String? title,
  String artist,
  String album,
  String genre,
  int year,
  int durationMs,
  Uint8List? cover,
});

const emptyLocalMetadata = (
  title: null,
  artist: '',
  album: '',
  genre: '',
  year: 0,
  durationMs: 0,
  cover: null,
);
