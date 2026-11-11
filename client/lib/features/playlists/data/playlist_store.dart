/// Playlists as far as the library menu needs them: a name and the songs in it.
/// Creating, naming and storing playlists is the playlist feature, which is
/// developed separately; this is only the place the context menu puts a song in.
class PlaylistStore {
  final Map<String, List<int>> _playlists = {};

  List<String> get names => _playlists.keys.toList();

  List<int> songs(String name) => _playlists[name] ?? const [];

  /// Adds a song to a playlist, taking the name as given. A song is in a playlist
  /// once, so the same row cannot be counted twice.
  void add(String name, int trackId) {
    final songs = _playlists.putIfAbsent(name, () => []);
    if (!songs.contains(trackId)) songs.add(trackId);
  }
}
