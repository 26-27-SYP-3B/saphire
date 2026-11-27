import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The covers already looked at, keyed by the identity of the byte list the library holds. The
/// same song keeps the same cover object, so a rebuild does not decode it again.
final Map<int, Future<Color?>> _cache = {};

/// One colour from a cover, for the full player's background. The image is decoded at 1x1, so
/// this is cheap; the result is cached with the cover. Null when the bytes are not a picture
/// the engine can read, in which case the player keeps its navy background.
Future<Color?> coverColor(Uint8List bytes) =>
    _cache.putIfAbsent(identityHashCode(bytes), () => _average(bytes));

Future<Color?> _average(Uint8List bytes) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1, targetHeight: 1);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    final pixels = data.buffer.asUint8List();
    if (pixels.length < 3) return null;
    return Color.fromARGB(255, pixels[0], pixels[1], pixels[2]);
  } catch (_) {
    return null;
  }
}
