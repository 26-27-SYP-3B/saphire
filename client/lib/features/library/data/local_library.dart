import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/local_playlist.dart';
import '../domain/local_track.dart';

const _key = 'local_library';
const _playlistsKey = 'local_playlists';
const _queueKey = 'local_queue';

/// The songs the user added from their own device, plus the playlists and the queue made
/// from them. Only title and path are stored; the file stays where it is, the app never
/// copies it, which is why a moved or deleted file is only noticed when it is played.
///
/// Playlists and the queue only refer to local songs. They live beside the songs rather
/// than in separate stores, so a single write keeps the three lists in step.
class LocalLibrary {
  LocalLibrary([this._storage]);

  /// Null in tests: the plugin has no platform there, so those libraries stay in memory.
  final FlutterSecureStorage? _storage;

  final List<LocalTrack> tracks = [];
  final List<LocalPlaylist> playlists = [];
  final List<LocalTrack> queue = [];

  /// A broken keychain must not keep the app from starting: it then looks like a first
  /// run, the same way SessionStore handles it.
  static Future<LocalLibrary> restore() async {
    const storage = FlutterSecureStorage();
    final library = LocalLibrary(storage);
    try {
      library.tracks.addAll(_readTracks(await storage.read(key: _key)));
      for (final entry in _decode(await storage.read(key: _playlistsKey)) as List) {
        final data = entry as Map<String, dynamic>;
        library.playlists.add(
          LocalPlaylist(name: data['name'] as String, songs: _tracks(data['songs'])),
        );
      }
      library.queue.addAll(_readTracks(await storage.read(key: _queueKey)));
    } catch (_) {
      return LocalLibrary(storage);
    }
    return library;
  }

  /// Takes one picked file. Returns null when it was taken, the message when it was
  /// refused, so the page can show the answer on that file and not add it.
  String? add({required String name, String? path, Uint8List? bytes}) {
    if (!name.toLowerCase().endsWith('.mp3')) {
      return 'nur MP3-Dateien werden übernommen';
    }
    // A renamed picture would pass on the name alone, so the first bytes have to agree.
    // A pick that came without bytes is on a device, where the player reports a file it
    // cannot open anyway.
    if (bytes != null && !isMp3(bytes)) {
      return 'die Datei ist keine gültige MP3-Datei';
    }

    // shortcut: the bytes of a browser pick stay in memory for the session. Upgrade:
    // store the file with the app's data, so a browser library survives a restart too.
    tracks.add(LocalTrack(title: name.split(RegExp(r'[/\\]')).last, path: path, bytes: bytes));
    _write();
    return null;
  }

  /// An MP3 starts with an ID3 tag or with a frame header: eleven set bits.
  bool isMp3(Uint8List bytes) {
    if (bytes.length < 3) return false;
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) return true; // "ID3"
    return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
  }

  /// A playlist needs a name nobody here has used yet. Null says the name was refused,
  /// so the page can ask for another one instead of inventing a number or a suffix.
  LocalPlaylist? createPlaylist(String name) {
    final clean = name.trim();
    if (clean.isEmpty || playlists.any((playlist) => playlist.name == clean)) return null;

    final playlist = LocalPlaylist(name: clean);
    playlists.add(playlist);
    _write();
    return playlist;
  }

  void addToPlaylist(LocalPlaylist playlist, LocalTrack track) {
    playlist.songs.add(track);
    _write();
  }

  void removeFromPlaylist(LocalPlaylist playlist, int index) {
    playlist.songs.removeAt(index);
    _write();
  }

  void setQueue(List<LocalTrack> tracks) {
    queue
      ..clear()
      ..addAll(tracks);
    _write();
  }

  void addToQueue(LocalTrack track) {
    queue.add(track);
    _write();
  }

  void removeFromQueue(int index) {
    queue.removeAt(index);
    _write();
  }

  void clearQueue() {
    queue.clear();
    _write();
  }

  void _write() {
    _storage?.write(key: _key, value: jsonEncode(_json(tracks))).ignore();
    _storage?.write(
      key: _playlistsKey,
      value: jsonEncode([
        for (final playlist in playlists) {'name': playlist.name, 'songs': _json(playlist.songs)},
      ]),
    ).ignore();
    _storage?.write(key: _queueKey, value: jsonEncode(_json(queue))).ignore();
  }

  /// Only a path survives a restart. The bytes of a browser pick live in memory for one
  /// session, so storing its title alone would restore a song that can never be opened.
  static List<Map<String, String?>> _json(List<LocalTrack> tracks) => [
        for (final track in tracks)
          if (track.path != null) {'title': track.title, 'path': track.path},
      ];

  /// The stored value of a list, decoded. A missing list is an empty one.
  static Object? _decode(String? saved) => saved == null ? const [] : jsonDecode(saved);

  static List<LocalTrack> _readTracks(String? saved) => _tracks(_decode(saved));

  static List<LocalTrack> _tracks(Object? data) => [
        for (final entry in data as List? ?? const [])
          LocalTrack(
            title: (entry as Map<String, dynamic>)['title'] as String,
            path: entry['path'] as String?,
          ),
      ];
}
