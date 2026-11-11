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
