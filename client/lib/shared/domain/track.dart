import 'dart:typed_data';

/// Where a song lives: in the shared server library or on this device.
enum TrackSource { server, local }

/// One song, whether the server has it or the device does. The library, a playlist picker and a
/// queue row all show this one shape, so a row is playable without the page having to know where
/// it came from first.
///
/// A server row has an [id] and no file of its own: the bytes come from `GET /api/music/{id}`.
/// A local row has `id == -1`, a [localPath] (a device file) or [localBytes] (a browser pick),
/// and the metadata its own tags name.
class Track {
  const Track({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.genre = '',
    this.year = 0,
    this.durationMs = 0,
    this.waveform = const [],
    this.uploadedBy = '',
    this.storedName = '',
    this.size = 0,
    this.contentType = '',
    this.uploadedAt = 0,
    this.source = TrackSource.server,
    this.localPath,
    this.localBytes,
    this.cover,
  });

  /// The server id, or -1 for a song that is only on this device.
  final int id;
  final String uploadedBy;
  final String title;

  /// What the file's tags name as the artist. Empty when the file does not say one.
  final String artist;

  /// What the file's tags name as the album. Empty when the file does not say one.
  final String album;

  /// What the file's tags name as the genre. Empty when the file does not say one.
  final String genre;

  /// The year the tags name, 0 when they name none.
  final int year;

  /// The playing time in milliseconds, 0 when the format cannot be measured.
  final int durationMs;

  /// The song's shape as 64 peaks from 0 to 255. Empty when the server could not decode it;
  /// the player then draws its neutral bars.
  final List<int> waveform;

  /// The name the file has inside the library folder: 16 random bytes as hex.
  final String storedName;
  final int size;
  final String contentType;
  final int uploadedAt;

  /// Whether the song is on this device or in the shared library.
  final TrackSource source;

  /// Where the local file is. Null for a server row and for a browser pick.
  final String? localPath;

  /// The bytes of a browser pick. Null on a device, where the file is read by its path.
  final Uint8List? localBytes;

  /// The cover the file's tags carry, when it has one.
  final Uint8List? cover;

  bool get isLocal => source == TrackSource.local;

  // JSON numbers arrive as double on the web, so the cast goes through num.
  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String,
    artist: json['artist'] as String? ?? '',
    album: json['album'] as String? ?? '',
    genre: json['genre'] as String? ?? '',
    year: (json['year'] as num?)?.toInt() ?? 0,
    durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    waveform: [
      for (final peak in json['waveform'] as List<dynamic>? ?? const [])
        (peak as num).toInt(),
    ],
    uploadedBy: json['uploaded_by'] as String? ?? '',
    storedName: json['stored_name'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    contentType: json['content_type'] as String? ?? '',
    uploadedAt: (json['uploaded_at'] as num?)?.toInt() ?? 0,
  );
}
