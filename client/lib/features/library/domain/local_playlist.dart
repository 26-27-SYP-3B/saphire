import 'local_track.dart';

/// A playlist the user made on the device: a name and the local songs in it. It has no
/// server id, because it only exists here, and no account is needed to own it.
class LocalPlaylist {
  LocalPlaylist({required this.name, List<LocalTrack>? songs}) : songs = songs ?? [];

  final String name;
  final List<LocalTrack> songs;
}
