import 'dart:typed_data';

/// The extensions the app reads as a song when it looks at a device folder. The server takes every
/// audio file it is given (see `server/src/music.rs`); this list is the device side's own limit, and
/// it keeps the library from offering a row the player may not be able to open. MIDI is left out
/// for that reason: it is audio on paper, but neither just_audio nor ExoPlayer can play it.
///
/// A list cannot name every format there is. A file with an extension nobody knows is not taken by
/// the device library; it can still be uploaded, because the server decides there.
const audioExtensions = {
  '.mp3', '.mp2', '.m4a', '.m4b', '.aac', '.wav', '.wave', '.flac', '.ogg', '.oga', '.opus',
  '.aif', '.aiff', '.wma', '.amr', '.au', '.mka', '.weba', '.caf', '.wv',
};

bool isAudioFile(String name) {
  final lower = name.toLowerCase();
  return audioExtensions.any(lower.endsWith);
}

bool _at(Uint8List bytes, int offset, List<int> signature) {
  if (offset + signature.length > bytes.length) return false;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[offset + i] != signature[i]) return false;
  }
  return true;
}

bool _text(Uint8List bytes, int offset, String value) =>
    _at(bytes, offset, [for (final unit in value.codeUnits) unit]);

/// Whether the first bytes are provably not audio: an image, a PDF, an archive, an executable or
/// text. This mirrors what the server recognizes (see `server/src/music.rs`).
///
/// Only the start of a file is looked at, so this can say "not a song" but never "a song": a wrong
/// file that passes is one the player refuses to open, with a message of its own. The magic of the
/// audio formats whose headers are printable (FLAC, Ogg, AIFF, MIDI, WavPack) is the exception the
/// text rule keeps, because `fLaC` is as printable as a letter.
bool looksLikeNotAudio(Uint8List bytes) {
  if (bytes.isEmpty) return true;

  // A BOM and leading whitespace are not part of the content; a signature behind them still
  // names the same format. shortcut: only those prefixes are skipped, like the server does.
  var start = 0;
  if (_at(bytes, 0, [0xEF, 0xBB, 0xBF])) start = 3;
  while (start < bytes.length && (bytes[start] == 0x09 || bytes[start] == 0x0A || bytes[start] == 0x0D || bytes[start] == 0x20)) {
    start += 1;
  }

  // A UTF-16 text file is text, not binary.
  if (_at(bytes, start, [0xFF, 0xFE]) || _at(bytes, start, [0xFE, 0xFF])) return true;

  // RIFF is a container: WAVE is audio, WebP and AVI are not.
  if (_at(bytes, start, [0x52, 0x49, 0x46, 0x46]) && bytes.length - start >= 12) {
    return !_text(bytes, start + 8, 'WAVE');
  }

  // HEIF and M4A share the ISO base media header; only the brand says which one this is.
  if (bytes.length - start >= 12 && _text(bytes, start + 4, 'ftyp')) {
    final brand = String.fromCharCodes(bytes.sublist(start + 8, start + 12));
    return const {'heic', 'heix', 'hevc', 'hevx', 'mif1', 'msf1'}.contains(brand);
  }

  // A tar archive has no signature at byte 0; its header names the format at byte 257.
  if (bytes.length - start >= 262 && _text(bytes, start + 257, 'ustar')) return true;

  const signatures = [
    [0x89, 0x50, 0x4E, 0x47], // PNG
    [0xFF, 0xD8, 0xFF], // JPEG
    [0x47, 0x49, 0x46, 0x38], // GIF
    [0x25, 0x50, 0x44, 0x46], // PDF
    [0x50, 0x4B, 0x03, 0x04], // ZIP and everything built on it
    [0x50, 0x4B, 0x05, 0x06], // an empty ZIP
    [0x50, 0x4B, 0x07, 0x08], // a spanned ZIP
    [0x1F, 0x8B], // gzip
    [0x7F, 0x45, 0x4C, 0x46], // ELF
    [0x4D, 0x5A], // a Windows executable
    [0x52, 0x61, 0x72, 0x21], // RAR
    [0x37, 0x7A, 0xBC, 0xAF], // 7z
    [0x42, 0x4D], // BMP
    [0x49, 0x49, 0x2A, 0x00], // TIFF, little endian
    [0x4D, 0x4D, 0x00, 0x2A], // TIFF, big endian
    [0x00, 0x00, 0x01, 0x00], // ICO
    [0xFD, 0x37, 0x7A, 0x58], // XZ
    [0x42, 0x5A, 0x68], // bzip2
    [0x28, 0xB5, 0x2F, 0xFD], // zstd
  ];
  for (final signature in signatures) {
    if (_at(bytes, start, signature)) return true;
  }

  // Text is not audio, unless it is the printable header of a real audio format.
  const audioMagic = [
    [0x66, 0x4C, 0x61, 0x43], // fLaC
    [0x49, 0x44, 0x33], // ID3
    [0x4F, 0x67, 0x67, 0x53], // OggS
    [0x46, 0x4F, 0x52, 0x4D], // FORM (AIFF)
    [0x4D, 0x54, 0x68, 0x64], // MThd (MIDI)
    [0x77, 0x76, 0x70, 0x6B], // wvpk (WavPack)
    [0x2E, 0x73, 0x6E, 0x64], // .snd (AU)
    [0x23, 0x21, 0x41, 0x4D], // #!AMR
  ];
  if (audioMagic.any((signature) => _at(bytes, start, signature))) return false;

  final end = start + 512 < bytes.length ? start + 512 : bytes.length;
  for (var i = start; i < end; i++) {
    final byte = bytes[i];
    if (byte != 0x09 && byte != 0x0A && byte != 0x0D && (byte < 0x20 || byte >= 0x7F)) return false;
  }
  return true;
}
