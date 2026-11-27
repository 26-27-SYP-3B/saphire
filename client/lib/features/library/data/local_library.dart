import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/utils/audio_format.dart';
import '../../../core/utils/local_metadata.dart';
import '../domain/local_playlist.dart';
import '../domain/local_track.dart';

const _key = 'local_library';
const _playlistsKey = 'local_playlists';
const _queueKey = 'local_queue';

/// A cover is stored with the song, in the same keychain entry as the library. It is cut off
/// at this size so a folder of photos cannot fill the secure storage; the tags still name the
/// title, artist and album of such a song.
const _maxStoredCoverBytes = 128 * 1024;

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
      for (final entry
          in _decode(await storage.read(key: _playlistsKey)) as List) {
        final data = entry as Map<String, dynamic>;
        library.playlists.add(
          LocalPlaylist(
            name: data['name'] as String,
            songs: _tracks(data['songs']),
          ),
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
  ///
  /// [metadata] is what the caller read from the file. The insertion itself stays synchronous;
  /// the app reads the tags with [addAsync] so a file on disk never blocks the frame.
  String? add({
    required String name,
    String? path,
    Uint8List? bytes,
    LocalAudioMetadata metadata = emptyLocalMetadata,
  }) {
    final refusal = _insert(
      name: name,
      path: path,
      bytes: bytes,
      metadata: metadata,
    );
    if (refusal == null) _write();
    return refusal;
  }

  /// The validation and the row insertion without the storage write, so a whole folder can be
  /// inserted first and written once instead of once per song.
  String? _insert({
    required String name,
    String? path,
    Uint8List? bytes,
    LocalAudioMetadata metadata = emptyLocalMetadata,
  }) {
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

    // The tags are what the file says about itself. A file with none keeps its name as the
    // title and the empty values; the pages show "Unbekannter Künstler" and a placeholder cover.
    final tags = metadata;
    final nameOnly = name.split(RegExp(r'[/\\]')).last;
    final tagged = tags.title?.trim();

    // shortcut: the bytes of a browser pick stay in memory for the session. Upgrade:
    // store the file with the app's data, so a browser library survives a restart too.
    tracks.add(
      LocalTrack(
        title: tagged == null || tagged.isEmpty ? nameOnly : tagged,
        path: path,
        bytes: bytes,
        artist: tags.artist,
        album: tags.album,
        genre: tags.genre,
        year: tags.year,
        durationMs: tags.durationMs,
        cover: tags.cover,
      ),
    );
    return null;
  }

  /// Reads one file's tags off the UI isolate and then adds it. The UI uses this for a single
  /// pick; [addAllAsync] is the folder path and reads the whole batch in one isolate.
  Future<String?> addAsync({
    required String name,
    String? path,
    Uint8List? bytes,
  }) async {
    final tags = path == null
        ? emptyLocalMetadata
        : await readLocalMetadataAsync(path);
    return add(name: name, path: path, bytes: bytes, metadata: tags);
  }

  /// Adds a whole pick in one go. The tags of every path are read in one background isolate
  /// and then inserted in the picked order; the returned list has one answer per file.
  Future<List<String?>> addAllAsync(
    List<({String name, String? path, Uint8List? bytes})> files,
  ) async {
    final paths = [
      for (final file in files)
        if (file.path != null) file.path!,
    ];
    final tags = paths.isEmpty
        ? const <LocalAudioMetadata>[]
        : await readLocalMetadataBatch(paths);
    var tagIndex = 0;
    final answers = [
      for (final file in files)
        _insert(
          name: file.name,
          path: file.path,
          bytes: file.bytes,
          metadata: file.path == null ? emptyLocalMetadata : tags[tagIndex++],
        ),
    ];
    if (answers.any((answer) => answer == null)) _write();
    return answers;
  }

  /// An MP3 starts with an ID3 tag or with a frame header: eleven set bits.
  bool isMp3(Uint8List bytes) {
    if (bytes.length < 3) return false;
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return true; // "ID3"
    }
    return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
  }

  /// A playlist needs a name nobody here has used yet. Null says the name was refused,
  /// so the page can ask for another one instead of inventing a number or a suffix.
  LocalPlaylist? createPlaylist(String name) {
    final clean = name.trim();
    if (clean.isEmpty || playlists.any((playlist) => playlist.name == clean)) {
      return null;
    }

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
    if (from < 1 || from > queue.length || to < 1 || to > queue.length) {
      return false;
    }
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
            for (final playlist in playlists)
              {'name': playlist.name, 'songs': _json(playlist.songs)},
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
  static List<Map<String, Object?>> _json(List<LocalTrack> tracks) => [
    for (final track in tracks)
      if (track.path != null)
        {
          'title': track.title,
          'path': track.path,
          'artist': track.artist,
          'album': track.album,
          'genre': track.genre,
          'year': track.year,
          'duration_ms': track.durationMs,
          if (track.cover != null &&
              track.cover!.length <= _maxStoredCoverBytes)
            'cover': base64Encode(track.cover!),
        },
  ];

  /// The stored value of a list, decoded. A missing list is an empty one.
  static Object? _decode(String? saved) =>
      saved == null ? const [] : jsonDecode(saved);

  static List<LocalTrack> _readTracks(String? saved) => _tracks(_decode(saved));

  static List<LocalTrack> _tracks(Object? data) {
    final tracks = <LocalTrack>[];
    for (final entry in data as List? ?? const []) {
      final row = entry as Map<String, dynamic>;
      final path = row['path'] as String?;
      // A browser pick never survives a restart: an older version stored its title without
      // bytes, so such a row must not come back as a song that can never be opened.
      if (path == null || path.isEmpty) continue;
      final cover = row['cover'] as String?;
      tracks.add(
        LocalTrack(
          title: row['title'] as String,
          path: path,
          artist: row['artist'] as String? ?? '',
          album: row['album'] as String? ?? '',
          genre: row['genre'] as String? ?? '',
          year: (row['year'] as num?)?.toInt() ?? 0,
          durationMs: (row['duration_ms'] as num?)?.toInt() ?? 0,
          cover: cover == null ? null : base64Decode(cover),
        ),
      );
    }
    return tracks;
  }
}
