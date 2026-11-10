import 'dart:io';

/// Whether the file a local song points at is still there. The app never copies a song,
/// so a file the user deleted or moved is only noticed when it is played.
bool fileExists(String path) => File(path).existsSync();
