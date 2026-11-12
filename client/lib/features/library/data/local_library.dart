import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/utils/audio_format.dart';
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

  /// The rows the person put in the queue themselves, as opposed to the ones a list filled.
  /// Keyed by the song itself, because the queue holds the songs themselves and a page
  /// recognizes a row by the song it is — a copy of a song would break that.
  final Set<LocalTrack> handAdded = {};

  /// Which list the queue was filled with. A row cannot say where it came from after the fill,
  /// so the page names the queue by this. Not stored: a restart starts a new queue.
  String? queueOrigin;

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
    if (!isAudioFile(name)) {
      return 'nur Audiodateien werden übernommen';
    }
    // A renamed picture would pass on the name alone, so the first bytes have to agree: an MP3
    // by its frame header, every other format by not being recognizable as something else. A
    // pick that came without bytes is on a device, where the player reports a file it cannot
    // open anyway.
    if (bytes != null) {
      final mp3 = name.toLowerCase().endsWith('.mp3');
      if (mp3 ? !isMp3(bytes) : looksLikeNotAudio(bytes)) {
        return 'die Datei ist keine gültige Audiodatei';
      }
    }
    // A folder import adds a whole list at once, and picking the same folder twice would
    // double every song. The path is what tells two files with the same name apart.
    if (path != null && tracks.any((track) => track.path == path)) {
      return 'ist schon in der Bibliothek';
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

  void setQueue(List<LocalTrack> tracks, {String? fromName}) {
    queue
      ..clear()
      ..addAll(tracks);
    // A fill comes from one list, so nothing in it was put there by hand.
    handAdded.clear();
    queueOrigin = fromName;
    _write();
  }

  void addToQueue(LocalTrack track) {
    queue.add(track);
    handAdded.add(track);
    _write();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= queue.length) return;
    handAdded.remove(queue[index]);
    queue.removeAt(index);
    _write();
  }

  /// Moves one row to another slot, 1-based like the server queue, so a page moves rows the
  /// same way in both modes. A device queue has no slots the server knows, so the order only
  /// exists here.
  bool move(int from, int to) {
    if (from < 1 || from > queue.length || to < 1 || to > queue.length) return false;
    if (from == to) return false;

    final row = queue.removeAt(from - 1);
    queue.insert(to - 1, row);
    _write();
    return true;
  }

  void clearQueue() {
    queue.clear();
    handAdded.clear();
    _write();
  }

  /// Writes are chained: a folder import adds hundreds of songs at once, and three writes
  /// to the same keys in parallel are not something the web plugin can handle. The values
  /// are read when the write runs, so the last one always stores the newest list.
  Future<void> _pending = Future.value();

  void _write() {
    _pending = _pending.then((_) async {
      final storage = _storage;
      if (storage == null) return;
      try {
        await storage.write(key: _key, value: jsonEncode(_json(tracks)));
        await storage.write(
          key: _playlistsKey,
          value: jsonEncode([
            for (final playlist in playlists) {'name': playlist.name, 'songs': _json(playlist.songs)},
          ]),
        );
        await storage.write(key: _queueKey, value: jsonEncode(_json(queue)));
      } catch (_) {
        // In memory the lists still work for this run, which is all a broken keychain allows.
      }
    });
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

  static List<LocalTrack> _tracks(Object? data) {
    final tracks = <LocalTrack>[];
    for (final entry in data as List? ?? const []) {
      final row = entry as Map<String, dynamic>;
      final path = row['path'] as String?;
      // A browser pick never survives a restart: an older version stored its title without
      // bytes, so such a row must not come back as a song that can never be opened.
      if (path == null || path.isEmpty) continue;
      tracks.add(LocalTrack(title: row['title'] as String, path: path));
    }
    return tracks;
  }
}
