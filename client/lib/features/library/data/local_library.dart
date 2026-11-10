import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../domain/local_track.dart';

const _key = 'local_library';

/// The songs the user added from their own device. Only title and path are stored; the
/// file stays where it is, the app never copies it, which is why a moved or deleted file
/// is only noticed when it is played.
class LocalLibrary {
  LocalLibrary([this._storage]);

  /// Null in tests: the plugin has no platform there, so those libraries stay in memory.
  final FlutterSecureStorage? _storage;

  final List<LocalTrack> tracks = [];

  /// A broken keychain must not keep the app from starting: it then looks like a first
  /// run, the same way SessionStore handles it.
  static Future<LocalLibrary> restore() async {
    const storage = FlutterSecureStorage();
    final library = LocalLibrary(storage);
    try {
      final saved = await storage.read(key: _key);
      if (saved == null) return library;

      for (final entry in jsonDecode(saved) as List<dynamic>) {
        final data = entry as Map<String, dynamic>;
        library.tracks.add(LocalTrack(title: data['title'] as String, path: data['path'] as String?));
      }
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

  void _write() {
    _storage?.write(
      key: _key,
      value: jsonEncode([
        for (final track in tracks) {'title': track.title, 'path': track.path},
      ]),
    ).ignore();
  }
}
