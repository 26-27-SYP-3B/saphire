import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/session_store.dart';
import '../../../core/storage/settings_store.dart';
import '../../../core/utils/pick_audio.dart';
import '../../../shared/widgets/app_shell.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/domain/user.dart';
import '../../library/data/library_repository.dart';
import '../../library/data/local_library.dart';
import '../../library/domain/local_track.dart';
import '../../player/data/queue_repository.dart';
import '../../player/domain/player.dart';
import '../../player/domain/queue.dart';
import '../../playlists/data/playlist_repository.dart';
import '../../upload/data/upload_repository.dart';
import '../../upload/domain/track.dart';

/// One file in the upload window: what it is, how far it got, what the server
/// said about it. Every picked file keeps its own row, so the results do not mix.
class _UploadFile {
  _UploadFile(this.name);

  final String name;
  int percent = 0;
  String? error;
  Track? track;
}

/// The greeting follows the time of day.
String greetingFor(DateTime now) {
  if (now.hour < 11) return 'Guten Morgen';
  if (now.hour < 18) return 'Guten Nachmittag';
  return 'Guten Abend';
}

/// What the server accepts (server/music.go): the client only says it up front,
/// the upload itself is still checked on the server.
const _uploadHint = 'Erlaubt: MP3, WAV, M4A, OGG, OPUS, FLAC, AAC · höchstens 500 MiB pro Datei';

/// What the local library takes: the files stay where the user keeps them, which is why
/// a moved file is only noticed when it is played. A long press puts one into the queue.
const _localHint =
    'MP3-Dateien von diesem Gerät · sie bleiben, wo sie sind, und spielen auch ohne Server · lange drücken für die Warteschlange';

/// The home screen: the app on the left, the greeting and the rows on the right.
/// Upload, playlists and the queue reach the server; the playlist rows below are the
/// placeholders from the mock, because there is no data behind them until a playlist is
/// opened on the Playlists page.
///
/// The search field is the one place this page shows real songs: the server has no search
/// endpoint, so the page reads the library once and filters what it got. The bar at the
/// bottom shows what the shared player is playing — this page does not own a player, it
/// only puts a song into the queue the player reads.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.uploads,
    required this.library,
    required this.queues,
    required this.playlists,
    required this.session,
    required this.player,
    this.pickAudio = pickAudioFiles,
    this.pickLocal = pickLocalAudioFiles,
    this.pickFolder = pickLocalFolder,
    this.settings,
    this.localLibrary,
  });

  final AuthRepository repository;
  final UploadRepository uploads;
  final LibraryRepository library;
  final QueueRepository queues;

  /// What the queue frame needs: the playlists a row can be added to, and the session the queue
  /// calls are made with.
  final PlaylistRepository playlists;
  final SessionStore session;
  final QueuePlayer player;
  final PickAudio pickAudio;
  final PickLocalAudio pickLocal;
  final PickLocalAudio pickFolder;

  /// Null in a test that does not care about local mode: the stores then stay in memory.
  final SettingsStore? settings;
  final LocalLibrary? localLibrary;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<_UploadFile> _files = [];
  List<Track> _library = [];
  final TextEditingController _search = TextEditingController();

  late final SettingsStore _settings = widget.settings ?? SettingsStore();
  late final LocalLibrary _local = widget.localLibrary ?? LocalLibrary();

  // The message from the session check. What a single file got is on its own row.
  String? _note;
  User? _user;
  // While the picker is open a second tap must not open it again.
  bool _picking = false;
  // While a queue call is running the same tap must not start it again.
  bool _busy = false;
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    // The player moves on its own when a song ends. Without a listener the bar would keep
    // showing the song that just finished.
    _changes = widget.player.changes.listen((_) {
      if (mounted) setState(() {});
    });
    // The name in the greeting is the account name, so it comes from the session
    // check: the session store holds only the token, nothing that says who we are.
    // Local mode has no account and no server to ask, so both reads are skipped there.
    if (!_settings.localMode) {
      _loadUser();
      // The search has nothing to filter until the library is here, so it is read once
      // when the page opens rather than on every keystroke.
      _loadLibrary();
    }
  }

  @override
  void dispose() {
    // The player belongs to the whole app, so only this page's listener is dropped here.
    _changes?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    try {
      final user = await widget.repository.currentSession();
      if (mounted) setState(() => _user = user);
    } on AuthException catch (error) {
      if (!mounted) return;
      // The server just said this token is gone, so the app must not keep it:
      // the router guard and the page then agree on the same session.
      widget.repository.logout();
      setState(() => _note = error.message);
    }
  }

  Future<void> _loadLibrary() async {
    try {
      final library = await widget.library.list();
      if (!mounted) return;
      setState(() => _library = library);
    } on LibraryException catch (error) {
      if (mounted) setState(() => _note = error.message);
    }
  }

  Future<void> _upload() async {
    if (_picking) return;

    setState(() => _picking = true);
    final List<PickedAudio>? picked;
    try {
      picked = await widget.pickAudio();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (picked == null) return;

    for (final file in picked) {
      final row = _UploadFile(file.name);
      // The screen can be gone by the time the next file of a batch is answered.
      if (!mounted) return;
      setState(() => _files.add(row));

      try {
        final track = await widget.uploads.upload(
          filename: file.name,
          bytes: file.bytes,
          // The percent is what Dio reports while this file is written; the server
          // answers after it has read and checked it.
          onProgress: (sent, total) {
            if (mounted && total > 0) setState(() => row.percent = (sent * 100 / total).round());
          },
        );
        if (mounted) setState(() => row.track = track);
      } on UploadException catch (error) {
        if (mounted) setState(() => row.error = error.message);
      }
    }
  }

  /// Adds picked files to the local library. Each file is checked on its own, so a
  /// refused one says why and the rest still land in the library. `folder` takes a whole
  /// directory instead of single files; a browser has no folders, so that path throws.
  Future<void> _addLocal({bool folder = false}) async {
    if (_picking) return;

    setState(() => _picking = true);
    final List<PickedLocal>? picked;
    try {
      picked = await (folder ? widget.pickFolder() : widget.pickLocal());
    } on UnsupportedError catch (error) {
      // A browser has no folders, so "try again" would never work there.
      if (mounted) setState(() => _note = '${error.message}');
      return;
    } catch (_) {
      // A folder that cannot be read is not a refused file, so no row can name it.
      if (mounted) setState(() => _note = 'Die Dateien konnten nicht gelesen werden. Versuch es erneut.');
      return;
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (picked == null || !mounted) return;

    if (picked.isEmpty) {
      if (folder) setState(() => _note = 'In diesem Ordner sind keine MP3-Dateien.');
      return;
    }

    setState(() {
      for (final file in picked!) {
        final refused = _local.add(name: file.name, path: file.path, bytes: file.bytes);
        // The message names the file, so with a batch it is clear which one was refused.
        if (refused != null) _note = '${file.name}: $refused';
      }
    });
  }

  /// The name the row shows: before the answer the picked name, after it the title
  /// the server stored (base name only, see api-docs.md).
  String _title(_UploadFile file) => file.track?.title ?? file.name;

  /// What a row says about its own file: the progress, or what the server answered.
  String _result(_UploadFile file) {
    if (file.error != null) return file.error!;
    if (file.track == null) return 'wird hochgeladen · ${file.percent} %';
    return '${file.track!.uploadedBy} · ${_size(file.track!.size)}';
  }

  bool _matches(String title) {
    final query = _search.text.trim().toLowerCase();
    return query.isEmpty || title.toLowerCase().contains(query);
  }

  /// What the search field finds among the server's songs. The server has no search endpoint
  /// (api-docs.md, Upcoming), so this filters the library the page loaded. Without a query
  /// nothing is a result, because without a query the page shows its sections instead.
  List<Track> _results() {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return [for (final entry in _library) if (_matches(entry.title)) entry];
  }

  /// The same search over the songs on this device, so a phone without a server can search too.
  List<LocalTrack> _localResults() {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return const [];
    return [for (final track in _local.tracks) if (_matches(track.title)) track];
  }

  /// One action on the shared player at a time. The page rebuilds after every one of them:
  /// a player that is only paused does not report anything, so a page that rebuilt only on
  /// the tap itself would keep the icon from before the tap.
  Future<void> _control(Future<void> Function() action) async {
    if (_busy) return;

    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      // A player that cannot open a song is not a JSON error, so the message is ours
      // there. A missing local file already says what is wrong.
      if (mounted) {
        setState(() {
          _note = switch (error) {
            QueueException(:final message) => message,
            PlaybackException(:final message) => message,
            _ => 'Das Lied konnte nicht gespielt werden: $error',
          };
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opening a search result fills the queue with that one song and plays it, the way the
  /// Playlists page starts a playlist. The player only ever reads a queue, so a song picked
  /// here and a song from a playlist play exactly the same way.
  Future<void> _play(Track entry) => _control(() async {
    widget.player.queue.fill(await widget.queues.fill(QueueSource.track(entry.id)));
    await widget.player.playCurrent();
  });

  /// A local song plays straight from the device: no queue call and no token, so it works
  /// with no server and no account.
  Future<void> _playLocal(LocalTrack track) => _control(() => widget.player.playLocal(track));

  /// Long-pressing a local card puts the song into the local queue. The queue in the bar
  /// then plays the list in order, still without a server.
  Future<void> _queueLocal(LocalTrack track) async {
    _local.addToQueue(track);
    // Said before the sync, so a failure to sync overwrites it instead of being hidden.
    setState(() => _note = '${track.title} in die Warteschlange gelegt.');
    await _control(() => widget.player.syncLocalQueue(_local.queue));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final results = _results();
    final localResults = _localResults();
    // While something is typed the page is a result list: the same songs under their sections
    // would say the same thing twice.
    final searching = _search.text.trim().isNotEmpty;

    return AppShell(
      selected: '/home',
      player: widget.player,
      queues: widget.queues,
      playlists: widget.playlists,
      library: widget.library,
      session: widget.session,
      localMode: _settings.localMode,
      localLibrary: _local,
      child: Column(
        children: [
          _topBar(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _greeting(),
                  if (_note != null) ...[
                    const SizedBox(height: 16),
                    Text(_note!, style: TextStyle(color: scheme.error)),
                  ],
                  if (results.isNotEmpty || localResults.isNotEmpty) ...[
                    _section('Suchergebnisse'),
                    _row([
                      for (final entry in results) _songCard(entry),
                      for (final track in localResults) _localCard(track),
                    ]),
                  ],
                  if (!searching) ...[
                    _section(
                      'Lokale Songs',
                      action: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Lokale Songs hinzufügen',
                            onPressed: _picking ? null : _addLocal,
                            icon: Icon(Icons.add, color: scheme.primary),
                          ),
                          IconButton(
                            tooltip: 'Ordner auswählen',
                            onPressed: _picking ? null : () => _addLocal(folder: true),
                            icon: Icon(Icons.create_new_folder, color: scheme.primary),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      _localHint,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    // A song on this device is found by the same field as one on the server, so
                    // the search works on a phone without a server too.
                    _row([for (final track in _local.tracks) _localCard(track)]),
                  ],
                  // Local mode has no server to upload to, so only the songs on
                  // this device are shown.
                  if (!_settings.localMode) ...[
                    _section(
                      'In aktueller Sitzung hinzugefügt',
                      action: IconButton(
                        tooltip: 'Datei auswählen',
                        onPressed: _picking ? null : _upload,
                        icon: Icon(Icons.add, color: scheme.primary),
                      ),
                    ),
                    Text(
                      _uploadHint,
                      style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    _row([
                      for (final file in _files.where((file) => _matches(_title(file)))) _fileCard(file),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = _user?.username;
    // The chevrons belong to the mock's wide frame and go nowhere; on a phone they would only
    // press the search field that is worth more than they are.
    final wide = MediaQuery.sizeOf(context).width >= AppShell.wideAt;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: Row(
        children: [
          if (wide) ...[
            Icon(Icons.chevron_left, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            const SizedBox(width: 16),
          ],
          Expanded(
            // The server has no search endpoint, so what is typed here filters the library
            // this page loaded once (see the shortcut in library/data/library_repository.dart).
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'Was möchtest du wiedergeben?'),
            ),
          ),
          const SizedBox(width: 16),
          Icon(Icons.notifications_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 16),
          PopupMenuButton<String>(
            tooltip: 'Konto',
            offset: const Offset(0, 44),
            onSelected: (value) {
              if (value == 'settings') {
                context.go('/settings');
                return;
              }
              // Local mode ends with a login: the form saves that choice, so the next
              // start asks for the password again instead of opening the home screen.
              if (value == 'connect') {
                // Ohne gespeicherten Server gibt es keine Adresse für das Login; der
                // Start fragt danach. Sonst ginge die Anmeldung an den Standard-Server.
                context.go(_settings.serverBase == null ? '/setup' : '/login');
                return;
              }
              if (value != 'logout') return;
              // There is no logout endpoint yet (api-docs.md, Upcoming), so
              // dropping the token here is the whole logout on this side.
              widget.repository.logout();
              context.go('/login');
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'settings', child: Text('Einstellungen')),
              if (_settings.localMode)
                const PopupMenuItem(value: 'connect', child: Text('Mit Server verbinden'))
              else
                const PopupMenuItem(value: 'logout', child: Text('Abmelden')),
            ],
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(17),
              ),
              child: Text(
                name == null ? '?' : name.substring(0, 1).toUpperCase(),
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _greeting() {
    final theme = Theme.of(context);
    final name = _user?.username;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            text: '${greetingFor(DateTime.now())}, ',
            style: theme.textTheme.displayLarge,
            children: [
              TextSpan(
                // The session check is still running on the first frames. Local mode has
                // no account, so there is nobody to name.
                text: _settings.localMode ? 'du' : (name ?? '…'),
                style: TextStyle(color: theme.colorScheme.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Hier sind deine Highlights für heute.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }

  /// A section title, with the control that belongs to the section at the end of the row: the
  /// title stays where the eye looks for it, and the button is a thumb's reach away on a phone.
  Widget _section(String title, {Widget? action}) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 12),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ?action,
        ],
      ),
    );
  }

  /// The cards of one section. A phone fits two of them side by side, and two are what fills the
  /// row: one 186 px card there would leave half the width empty.
  Widget _row(List<Widget> cards) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 420;
        final width = wide ? 186.0 : (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final card in cards) SizedBox(width: width, height: 186, child: card)],
        );
      },
    );
  }

  Widget _card(({String title, String meta, IconData icon}) item) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        border: Border.all(color: scheme.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The mock has pictures here. Until the library has an API, a
            // gradient in the brand color stands in for one.
            Container(
              width: double.infinity,
              height: 96,
              alignment: Alignment.bottomLeft,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary.withValues(alpha: 0.35), scheme.surface],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Icon(item.icon, color: scheme.onSurface),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              item.title,
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              item.meta,
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  /// A real library song: the same card as the placeholder rows, but it can be opened,
  /// because a search result is something the user means to play. The line under the title
  /// says where the row came from, so a real song can be told apart from a mock row.
  Widget _songCard(Track entry) {
    return InkWell(
      onTap: _busy ? null : () => _play(entry),
      child: _card((title: entry.title, meta: 'Bibliothek', icon: Icons.audio_file)),
    );
  }

  /// A local song: the same card as a library song, but the line under the title says it
  /// comes from this device and not from the server.
  Widget _localCard(LocalTrack track) {
    return InkWell(
      onTap: _busy ? null : () => _playLocal(track),
      onLongPress: _busy ? null : () => _queueLocal(track),
      child: _card((title: track.title, meta: 'Lokal', icon: Icons.audiotrack)),
    );
  }

  /// One picked file: its name and the answer for this file only, so the results
  /// of a batch do not mix into one message.
  Widget _fileCard(_UploadFile file) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = file.error != null;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        // A refused file is marked as refused, so the row can be told apart.
        border: Border.all(color: failed ? scheme.error : scheme.outline),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(failed ? Icons.error : Icons.audio_file, color: failed ? scheme.error : scheme.primary),
            const Spacer(),
            Text(
              _title(file),
              style: theme.textTheme.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Text(
              _result(file),
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            // The bar is only for a file that is still on its way.
            if (!failed && file.track == null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: file.percent / 100, minHeight: 3),
            ],
          ],
        ),
      ),
    );
  }

  String _size(int bytes) {
    return bytes >= 1000000 ? '${(bytes / 1000000).toStringAsFixed(1)} MB' : '${(bytes / 1000).round()} kB';
  }
}


