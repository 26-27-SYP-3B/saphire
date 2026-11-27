# Saphire Client

The Flutter app for Saphire: it streams the songs of a Saphire server and plays the audio files
on the device. The layout follows Spotify, with marine blue where Spotify has green.

## Running

```bash
flutter pub get
flutter run
```

The server address is asked for on the first start and kept on the device. For a phone the default
`127.0.0.1` is the phone itself, so enter the LAN address of the development machine in the setup
(for the Android emulator that is `10.0.2.2`). The same address can be changed later under
Einstellungen.

```bash
flutter analyze
flutter test
flutter build apk --release
```

## What the app does

- **Home** – greeting, a search over the library the app read, local songs, and an upload button
  that sends files to the shared server library.
- **Suche** – one field over the server library and the songs on this device.
- **Bibliothek** – the Spotify library: filter chips (Playlists, Alben, Künstler*innen, Lokal), the
  list/grid switch, sort and metadata filters, a right-click menu on a row, and a "+" that creates
  a playlist or adds local files.
- **Playlists** – the create sheet Spotify opens from "+", a detail header with a large cover,
  play and shuffle, "Songs hinzufügen", and a three-dot menu per song (queue, another playlist,
  remove). Playlist covers are kept on the device: the server stores only a name and positions.
- **Warteschlange** – the sections "Wird gerade gespielt", "Als Nächstes in der Warteschlange" and
  "Als Nächstes aus: <Quelle>", with drag and drop to reorder and swipe or the menu to remove.
- **Player** – a mini player above the phone navigation and a desktop bar across the bottom, both
  over one shared queue and one audio player. The full player has a cover, heart, seek line,
  shuffle/previous/play/next/repeat, queue, share and device sheet; swiping down closes it.
- **Lokale Songs** – mp3, flac, m4a and the other formats `audio_metadata_reader` understands are
  read with their title, artist, album, genre, year, length and cover. The file stays where it is;
  the app stores its path and metadata, never a copy.

## Layout

- One `AppShell` draws the frame: a sidebar with `Deine Bibliothek` and a resizable width from
  800 px, the bottom navigation on a phone, the queue column or drop-up, and the player.
- `PlayerBar` and `PlayerView` are two views of the same `QueuePlayer`; the app creates exactly one
  queue and one player in `main.dart`.
- Colors live in `lib/app/theme.dart`; a widget takes its colors from the `ColorScheme` or the
  palette constants there.
- One `Track` (`lib/shared/domain/track.dart`) represents a server song and a device song; its
  `source` says which. `QueueEntry` adds the queue position and is what the player reads.

## Known limits

- Likes (the heart) are kept for the running session only: there is no favourites endpoint yet.
- The queue order move is device state until the server has a reorder endpoint (api-docs.md,
  Upcoming).
- There is no device selection endpoint; the device sheet names the current device and says that
  no other one is connected.
- Reading the tags of a large folder happens on the UI isolate; a folder import of hundreds of
  files can pause briefly.
