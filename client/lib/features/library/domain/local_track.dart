import 'dart:typed_data';

import '../../../shared/domain/track.dart';

/// A song on the device: what it is called, where it is, and what its tags say about it.
///
/// A pick on a device gives a path, and that is what survives a restart. A pick in a browser
/// gives bytes only, so such a song lives as long as the app runs.
class LocalTrack {
  const LocalTrack({
    required this.title,
    this.path,
    this.bytes,
    this.artist = '',
    this.album = '',
    this.genre = '',
    this.year = 0,
    this.durationMs = 0,
    this.cover,
  });

  final String title;
  final String? path;
  final Uint8List? bytes;

  /// What the file's tags name. Empty when it has no tags, in which case the pages show a dash.
  final String artist;
  final String album;
  final String genre;
  final int year;
  final int durationMs;

  /// The cover the tags carry, when they do. Kept with the song so the library row can show it.
  final Uint8List? cover;

  /// The same song in the shared track shape, so a library row and a queue row do not have to
  /// care where a song came from.
  Track toTrack({int id = -1}) => Track(
    id: id,
    title: title,
    artist: artist,
    album: album,
    genre: genre,
    year: year,
    durationMs: durationMs,
    source: TrackSource.local,
    localPath: path,
    localBytes: bytes,
    cover: cover,
  );
}

/// The other direction: a row in the shared shape that is a file on this device, passed to the
/// player that only knows how to open a path or bytes.
extension TrackOnDevice on Track {
  LocalTrack toLocalTrack() => LocalTrack(
    title: title,
    path: localPath,
    bytes: localBytes,
    artist: artist,
    album: album,
    genre: genre,
    year: year,
    durationMs: durationMs,
    cover: cover,
  );
}
