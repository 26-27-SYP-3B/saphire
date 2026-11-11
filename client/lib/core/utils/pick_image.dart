import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

typedef PickImage = Future<Uint8List?> Function();

/// The largest cover that is taken. The image is kept with the app's settings, and a
/// browser keeps those in a storage of a few megabytes, so a big photo is refused rather
/// than stored half-way.
const maxCoverBytes = 1024 * 1024;

/// A cover image from the device. Only the bytes are read: where the file lies does not
/// matter, because the image is copied into the app's own storage.
Future<Uint8List?> pickImageFile() async {
  final picked = await FilePicker.pickFiles(type: FileType.image);
  if (picked.isEmpty) return null;
  return picked.first.readAsBytes();
}

/// A picked file has to be a picture the app can draw. The picker's filter is an offer,
/// not a check: a browser happily offers an SVG, and a renamed file passes on its name
/// alone. The magic bytes are what decides, the same way LocalLibrary checks an MP3.
bool isImage(Uint8List bytes) {
  bool at(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[offset + i] != signature[i]) return false;
    }
    return true;
  }

  return at(0, const [0x89, 0x50, 0x4E, 0x47]) || // PNG
      at(0, const [0xFF, 0xD8, 0xFF]) || // JPEG
      at(0, const [0x47, 0x49, 0x46]) || // GIF
      at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50]); // WebP
}
