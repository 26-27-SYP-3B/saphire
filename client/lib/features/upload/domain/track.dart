/// One song in the shared library, exactly as POST /api/music/upload answers it.
/// The library belongs to the server, not to a user, so the answer names the
/// uploader — a plain user id would show nothing in a shared list.
class Track {
  const Track({
    required this.id,
    required this.uploadedBy,
    required this.title,
    required this.storedName,
    required this.size,
    required this.contentType,
    required this.uploadedAt,
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
    uploadedBy: json['uploaded_by'] as String,
    title: json['title'] as String,
    storedName: json['stored_name'] as String,
    size: (json['size'] as num).toInt(),
    contentType: json['content_type'] as String,
    uploadedAt: (json['uploaded_at'] as num).toInt(),
  );
}
