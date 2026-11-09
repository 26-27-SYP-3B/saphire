/// One song in the shared library, exactly as GET /api/music answers it: id and title.
/// The other fields of Track (stored_name, size, content_type) are not in this answer,
/// so this is the shape the list really has. A page that wants the bytes of one of these
/// uses GET /api/music/{id}, which is what the player does.
class LibraryEntry {
  const LibraryEntry({required this.id, required this.title});

  final int id;
  final String title;

  // JSON numbers arrive as double on the web, so the cast goes through num.
  factory LibraryEntry.fromJson(Map<String, dynamic> json) => LibraryEntry(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String,
  );
}
