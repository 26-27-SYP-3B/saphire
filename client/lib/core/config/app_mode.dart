/// Whether the app works with a server or only with the songs on the device. The
/// user chooses this at the start screen; it is not stored, because the local
/// library is stored and the choice itself is only for this run.
class AppMode {
  bool local = false;
}
