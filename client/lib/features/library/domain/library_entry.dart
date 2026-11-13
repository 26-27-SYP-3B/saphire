/// One row of GET /api/music. The answer carries id and title only: the name the file
/// has inside the library folder stays on the server, and a song is heard through
/// GET /api/music/{id}. So the id is not a detail here, it is the only way to a song.
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
