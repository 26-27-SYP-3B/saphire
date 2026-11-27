import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as tags;

import 'local_metadata.dart';

/// Reads title, artist, album, genre, year, length and the front cover from a local file.
/// mp3 (ID3), flac (Vorbis), m4a/mp4 (iTunes ilst), ogg/opus, wav and aiff are covered by the
/// package; an unreadable or untagged file keeps the empty values and its file name.
LocalAudioMetadata readLocalMetadata(String path) {
  try {
    final metadata = tags.readMetadata(File(path), getImage: true);
    final pictures = metadata.pictures;
    return (
      title: metadata.title,
      artist: metadata.artist ?? '',
      album: metadata.album ?? '',
      genre: metadata.genres.join(', '),
      year: metadata.year?.year ?? 0,
      durationMs: metadata.duration?.inMilliseconds ?? 0,
      cover: pictures.isEmpty ? null : pictures.first.bytes,
    );
  } catch (_) {
    // A broken tag is not a broken song: the file still plays, it just has no metadata.
    return emptyLocalMetadata;
  }
}
