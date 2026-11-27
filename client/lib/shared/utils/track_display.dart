import '../domain/track.dart';

/// What a row says when the file has no artist tag. It is a value the user can read, not a
/// dash: "no tag" and "no artist known" are the same thing here.
const unknownArtist = 'Unbekannter Künstler';

/// What a row says when the file's length is unknown. A dash is honest where a guess would not
/// be; there is no "unknown duration" phrase in a track list.
const unknownDuration = '–';

/// The artist a row shows: the tag, or [unknownArtist]. Nothing is guessed from the file name;
/// the name is a fallback for the title only.
String displayArtist(Track track) =>
    track.artist.trim().isEmpty ? unknownArtist : track.artist.trim();

/// The length as mm:ss, or [unknownDuration] when the file does not say one.
String displayDuration(Track track) => formatDurationMs(track.durationMs);

/// The same format for a queue entry, which carries milliseconds instead of a whole Track.
String formatDurationMs(int durationMs) {
  if (durationMs <= 0) return unknownDuration;
  final seconds = durationMs ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// The line under a title in a song list: artist and length, the pair every list shows.
String displayMeta(Track track) =>
    '${displayArtist(track)} · ${displayDuration(track)}';
