import '../utils/pick_audio.dart';

/// A browser has no folders: a pick there is a list of files. Saying so is better than
/// pretending the folder was empty.
Future<List<PickedLocal>> readFolder(String path) async =>
    throw UnsupportedError('Ordner können in einem Browser nicht gelesen werden.');
