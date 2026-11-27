import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as tags;

import 'local_metadata.dart';

/// Reads title, artist, album, genre, year, length and the front cover from a local file.
/// mp3 (ID3), flac (Vorbis), m4a/mp4 (iTunes ilst), ogg/opus, wav and aiff are covered by the
/// package; an unreadable or untagged file keeps the empty values and its file name.
// Keyed by path, because the library stores the values after the first read. A file that
// changes under the same path keeps its old tags until the app restarts; the library does not
// re-read a song that is already in it. shortcut: no file-watch, upgrade if songs are edited
// while the app runs.
final Map<String, Future<LocalAudioMetadata>> _cache = {};

/// Reads one file off the UI isolate. A path that was read before is served from the cache.
/// A path that is no longer there is empty immediately, without spawning an isolate.
Future<LocalAudioMetadata> readLocalMetadataAsync(String path) =>
    _cache.putIfAbsent(
      path,
      () => File(path).existsSync()
          ? _inIsolate(path)
          : Future.value(emptyLocalMetadata),
    );

/// Reads a whole folder in one isolate instead of spawning one isolate per file. The covers
/// travel back with the records, so a batch of hundreds of songs is one round trip.
Future<List<LocalAudioMetadata>> readLocalMetadataBatch(
  List<String> paths,
) async {
  final unique = <String>{...paths};
  final missing = [
    for (final path in unique)
      if (!_cache.containsKey(path)) path,
  ];
  for (final path in missing) {
    if (!File(path).existsSync()) {
      _cache[path] = Future.value(emptyLocalMetadata);
    }
  }
  missing.removeWhere((path) => !File(path).existsSync());
  if (missing.isNotEmpty) {
    final results = await Isolate.run(
      () => [for (final path in missing) readLocalMetadata(path)],
    );
    for (var index = 0; index < missing.length; index++) {
      _cache[missing[index]] = Future.value(results[index]);
    }
  }
  return [for (final path in paths) await _cache[path]!];
}

Future<LocalAudioMetadata> _inIsolate(String path) async {
  try {
    return await Isolate.run(() => readLocalMetadata(path));
  } catch (_) {
    // Spawning an isolate can fail on a restricted platform; the song can still be played,
    // it just has no tags.
    return emptyLocalMetadata;
  }
}

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
