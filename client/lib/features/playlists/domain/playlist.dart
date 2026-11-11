/// A playlist as POST /api/playlists answers it. A playlist belongs to the user who
/// created it — the library is shared, so this is the only user data the server keeps.
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.songCount,
  });

  final int id;
  final String name;
  final int createdAt;

  /// How many songs the playlist has. The list answer gives the count but not the
  /// songs, so a page that shows playlists does not get every song of every playlist.
  final int songCount;

  // JSON numbers arrive as double on the web, so the cast goes through num.
  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    createdAt: (json['created_at'] as num).toInt(),
    songCount: (json['song_count'] as num).toInt(),
  );
}

/// One song inside a playlist, at its position. Positions are 1-based and always
/// contiguous, so a row can be addressed without knowing what was removed before it.
/// A song can appear twice, at different positions: a playlist is an order, not a set.
class PlaylistSong {
  const PlaylistSong({required this.position, required this.trackId, required this.title});

  final int position;
  final int trackId;
  final String title;

  factory PlaylistSong.fromJson(Map<String, dynamic> json) => PlaylistSong(
    position: (json['position'] as num).toInt(),
    trackId: (json['track_id'] as num).toInt(),
    title: json['title'] as String,
  );
}

/// A playlist with its songs, as GET /api/playlists/{id} answers it. The titles come
/// from the library rows: a playlist stores references, not copies.
class PlaylistWithSongs {
  const PlaylistWithSongs({required this.playlist, required this.songs});

  final Playlist playlist;
  final List<PlaylistSong> songs;

  factory PlaylistWithSongs.fromJson(Map<String, dynamic> json) => PlaylistWithSongs(
    playlist: Playlist.fromJson(json),
    // An empty playlist answers [], never null.
    songs: ((json['songs'] as List?) ?? const [])
        .map((entry) => PlaylistSong.fromJson(entry as Map<String, dynamic>))
        .toList(),
  );
}
