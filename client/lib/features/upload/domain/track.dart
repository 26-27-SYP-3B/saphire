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
    this.durationMs = 0,
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

  /// The playing time in milliseconds, 0 when the format cannot be measured.
  final int durationMs;

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
    durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
    uploadedBy: json['uploaded_by'] as String? ?? '',
    storedName: json['stored_name'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    contentType: json['content_type'] as String? ?? '',
    uploadedAt: (json['uploaded_at'] as num?)?.toInt() ?? 0,
  );
}
