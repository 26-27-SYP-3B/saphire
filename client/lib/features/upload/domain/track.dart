/// One song in the shared library, exactly as POST /api/music/upload answers it.
/// The library belongs to the server, not to a user, so the answer names the
/// uploader — a plain user id would show nothing in a shared list.
class Track {
  // Only id and title are in every answer. The library list (api-docs.md,
  // GET /api/music) sends just those, so the rest reads as empty rather than
  // throwing on a row that does not have it.
  const Track({
    required this.id,
    required this.title,
    this.uploadedBy = '',
    this.storedName = '',
    this.size = 0,
    this.contentType = '',
    this.uploadedAt = 0,
  });

  final int id;
  final String uploadedBy;
  final String title;

  /// The name the file has inside the library folder: 16 random bytes as hex.
  final String storedName;
  final int size;
  final String contentType;
  final int uploadedAt;

  // JSON numbers arrive as double on the web, so the cast goes through num.
  factory Track.fromJson(Map<String, dynamic> json) => Track(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String,
    uploadedBy: json['uploaded_by'] as String? ?? '',
    storedName: json['stored_name'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    contentType: json['content_type'] as String? ?? '',
    uploadedAt: (json['uploaded_at'] as num?)?.toInt() ?? 0,
  );
}
