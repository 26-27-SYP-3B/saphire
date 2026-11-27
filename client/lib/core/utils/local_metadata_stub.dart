import 'local_metadata.dart';

/// A browser has no file path to parse, and a browser pick has only its bytes. Such a song keeps
/// its name and no tags.
LocalAudioMetadata readLocalMetadata(String path) => emptyLocalMetadata;

Future<LocalAudioMetadata> readLocalMetadataAsync(String path) async =>
    emptyLocalMetadata;

Future<List<LocalAudioMetadata>> readLocalMetadataBatch(
  List<String> paths,
) async => [for (final _ in paths) emptyLocalMetadata];
