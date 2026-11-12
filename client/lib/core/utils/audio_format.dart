import 'dart:typed_data';

/// The extensions the app reads as a song when it looks at a device folder. The server takes every
/// audio file it is given (see `server/src/music.rs`), and the device side should not be stricter
/// than the server: a folder of M4A or FLAC songs is still a folder of songs.
///
/// A list cannot name every format there is. A file with an extension nobody knows is not offered
/// by a folder import; picking it by hand still works, because the player decides there.
const audioExtensions = {
  '.mp3', '.mp2', '.m4a', '.m4b', '.aac', '.wav', '.wave', '.flac', '.ogg', '.oga', '.opus',
  '.aif', '.aiff', '.wma', '.amr', '.au', '.mka', '.weba', '.mid', '.midi', '.caf', '.wv',
};

bool isAudioFile(String name) {
  final lower = name.toLowerCase();
  return audioExtensions.any(lower.endsWith);
}

/// Whether the first bytes are provably not audio: an image, a PDF, an archive, an executable.
///
/// Only the start of a file is looked at, so this can say "not a song" but never "a song": a wrong
/// file that passes is one the player refuses to open, with a message of its own. Text is not
/// checked here — the start of a real FLAC (`fLaC`) is printable too, and a text file is already
/// refused by its name.
bool looksLikeNotAudio(Uint8List bytes) {
  const signatures = [
    [0x89, 0x50, 0x4E, 0x47], // PNG
    [0xFF, 0xD8, 0xFF], // JPEG
    [0x47, 0x49, 0x46, 0x38], // GIF
    [0x25, 0x50, 0x44, 0x46], // PDF
    [0x50, 0x4B, 0x03, 0x04], // ZIP and everything built on it
    [0x1F, 0x8B], // gzip
    [0x4D, 0x5A], // a Windows executable
  ];
  for (final signature in signatures) {
    if (bytes.length < signature.length) continue;
    var same = true;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) {
        same = false;
        break;
      }
    }
    if (same) return true;
  }
  return false;
}
