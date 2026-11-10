import 'dart:typed_data';

/// A song on the device: what it is called and where it is.
///
/// A pick on a device gives a path, and that is what survives a restart. A pick in a
/// browser gives bytes only, so such a song lives as long as the app runs.
class LocalTrack {
  const LocalTrack({required this.title, this.path, this.bytes});

  final String title;
  final String? path;
  final Uint8List? bytes;
}
