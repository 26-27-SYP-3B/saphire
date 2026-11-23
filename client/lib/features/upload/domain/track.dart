/// One song in the shared library, exactly as the server answers it
/// (api-docs.md: POST /api/music/upload and GET /api/music).
/// The library belongs to the server, not to a user, so the answer names the
/// uploader — a plain user id would show nothing in a shared list.
class Track {
  // Only id and title are in every answer. A row that does not have the rest reads
  // as empty rather than throwing, because a file with no tags has no artist and no
  // length the server can know.
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
  });

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
      for (final peak in json['waveform'] as List<dynamic>? ?? const []) (peak as num).toInt(),
    ],
    uploadedBy: json['uploaded_by'] as String? ?? '',
    storedName: json['stored_name'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    contentType: json['content_type'] as String? ?? '',
    uploadedAt: (json['uploaded_at'] as num?)?.toInt() ?? 0,
  );
}
